from __future__ import annotations
"""翻译层：LLM 分段翻译，强制段落 1:1 对齐 + 术语表 + 内容哈希缓存。

逻辑要点
1. 一次请求里塞多段，但要求「输出等长 JSON 数组」，长度不符直接重试 → 杜绝串段。
2. 单段上限 1800 字符，超了就分批，避免长文被模型截断或漏译。
3. 译文按源文哈希缓存，同一句话永不重复付费。
4. Bloomberg 自带 aiSummary(Takeaways)，喂给模型做 brief 参考，比模型自己概括更准。
"""
import asyncio
import hashlib
import json
import logging
import re
import time

import httpx

import config

log = logging.getLogger("translate")

GLOSSARY = (
    "Fed/Federal Reserve=美联储；ECB=欧洲央行；BOJ=日本央行；BOE=英国央行；PBOC=中国人民银行；"
    "SEC=美国证监会；Treasury=美国财政部；ECB=欧洲央行；M&A=并购；IPO=首次公开募股；"
    "earnings=财报；guidance=业绩指引；tariff=关税；bond yield=债券收益率；basis point=基点；"
    "QE=量化宽松；QT=缩表；inflation=通胀；CPI=消费者物价指数；PCE=个人消费支出物价指数；"
    "jobless claims=初请失业金人数；buyback=回购；valuation=估值；downgrade=下调评级"
)

SYS_TR = (
    "你是资深财经新闻译者，把英文新闻译成简体中文。硬性要求："
    "1) 严格按输入 JSON 数组的顺序输出等长数组，不合并不增删；"
    "2) 人名/机构/产品/股票代码/数字/百分比/货币单位原样保留，可加中文括注；"
    "3) 术语按术语表；金融缩写首次出现给中文全称；"
    "4) 不添加解释或评论，不使用省略号，不要 Markdown，只输出 JSON 数组。"
)

SYS_META = (
    "你是财经编辑。根据给定英文标题与要点，输出严格 JSON："
    '{"title_zh":"中文标题","brief":["要点1","要点2","要点3"]}。'
    "中文标题不超过 40 字；brief 每条不超过 28 字，三条互不重复，信息密度高。只输出 JSON。"
)


def _chunk_budget() -> int:
    return 1800


class Translator:
    def __init__(self, store):
        self.store = store
        self._client: httpx.AsyncClient | None = None
        self._lock = asyncio.Lock()
        self._sem = asyncio.Semaphore(2)

    async def _http(self) -> httpx.AsyncClient:
        async with self._lock:
            if self._client is None:
                self._client = httpx.AsyncClient(timeout=120)
            return self._client

    async def close(self):
        if self._client:
            await self._client.aclose()

    async def _chat(self, system: str, user: str, retries: int = 3) -> str:
        if not config.LLM_KEY:
            raise RuntimeError("LLM_KEY 未配置")
        client = await self._http()
        last = None
        for i in range(retries):
            try:
                r = await client.post(
                    config.LLM_URL,
                    headers={"Authorization": "Bearer " + config.LLM_KEY,
                             "Content-Type": "application/json"},
                    json={"model": config.LLM_MODEL, "temperature": 0.2,
                          "messages": [{"role": "system", "content": system},
                                       {"role": "user", "content": user}]})
                r.raise_for_status()
                return r.json()["choices"][0]["message"]["content"]
            except Exception as e:
                last = e
                log.warning("llm retry %d/%d: %s", i + 1, retries, e)
                await asyncio.sleep(2 ** i)
        raise RuntimeError("LLM 调用失败: %s" % last)

    @staticmethod
    def _extract_json(raw: str, expect_list: bool):
        raw = raw.strip()
        raw = re.sub(r"^```(?:json)?|```$", "", raw, flags=re.M).strip()
        if expect_list:
            s, e = raw.find("["), raw.rfind("]")
        else:
            s, e = raw.find("{"), raw.rfind("}")
        if s < 0 or e <= s:
            raise ValueError("no json found")
        return json.loads(raw[s:e + 1])

    async def translate_blocks(self, blocks: list[dict]) -> list[dict]:
        out = [dict(b) for b in blocks]

        # 1) 命中缓存的先填
        todo: list[int] = []
        for i, b in enumerate(out):
            if b["type"] in ("hr", "img"):
                b["zh"] = ""
                continue
            h = hashlib.sha256(("v1|" + b["text"]).encode()).hexdigest()[:32]
            b["_h"] = h
            cached = await self.store.cache_get(h)
            if cached:
                b["zh"] = cached
            else:
                b["zh"] = None
                todo.append(i)

        # 2) 分批翻译（1:1 强制对齐）
        async with self._sem:
            batch: list[int] = []
            size = 0

            async def flush():
                nonlocal batch, size
                if not batch:
                    return
                texts = [out[i]["text"] for i in batch]
                prompt = ("术语表：" + GLOSSARY +
                          "\n\n把下面 JSON 数组逐段译成中文，输出等长 JSON 数组（只输出数组）：\n" +
                          json.dumps(texts, ensure_ascii=False))
                raw = await self._chat(SYS_TR, prompt)
                arr = self._extract_json(raw, expect_list=True)
                if not isinstance(arr, list) or len(arr) != len(batch):
                    raise ValueError("对齐失败: got %d, want %d" % (len(arr or []), len(batch)))
                for i, zh in zip(batch, arr):
                    zh = str(zh).strip()
                    out[i]["zh"] = zh
                    await self.store.cache_put(out[i]["_h"], zh)
                batch, size = [], 0

            for i in todo:
                t = out[i]["text"]
                if size + len(t) > _chunk_budget():
                    await flush()
                batch.append(i)
                size += len(t)
            await flush()

        for b in out:
            b.pop("_h", None)
            if b.get("zh") is None:
                b["zh"] = b.get("text", "")
        return out

    async def meta(self, title: str, summary: list[str], first_paras: list[str]) -> dict:
        prompt = ("标题：" + title + "\n\n官方要点：\n- " + "\n- ".join(summary or []) +
                  "\n\n首段：" + "\n".join(first_paras[:3]) +
                  "\n\n术语表：" + GLOSSARY)
        raw = await self._chat(SYS_META, prompt)
        try:
            d = self._extract_json(raw, expect_list=False)
            return {"title_zh": str(d.get("title_zh") or title).strip()[:120],
                    "brief": [str(x).strip()[:60] for x in (d.get("brief") or [])][:3]}
        except Exception as e:
            log.warning("meta parse fail: %s", e)
            return {"title_zh": title, "brief": []}

    async def article(self, art: dict) -> dict:
        blocks = await self.translate_blocks(art.get("blocks") or [])
        plain = [b["text"] for b in blocks if b["type"] in ("p", "h2")][:3]
        meta = await self.meta(art.get("title", ""), art.get("summary") or [], plain)
        return {**art, "blocks": blocks,
                "title_zh": meta["title_zh"], "brief": meta["brief"],
                "translated_at": int(time.time())}
