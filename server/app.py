from __future__ import annotations
"""FastAPI 编排层。

流水线状态机
  pending --fetch--> --translate--> --save--> --push--> done
      \\--(3 次重试失败)--> failed(reason)

设计要点
1. 采集线程固定 45s 一轮；每轮只把「新 key」丢进处理队列，绝不重复抓取。
2. 抓取/翻译都限并发（默认 2），避免把目标站点和 LLM 打爆。
3. 首次部署保护：published 超过 MAX_PUSH_AGE_SECONDS 的老文章只入库不推送，
   否则一上线你会被 200 条历史推送炸醒。
4. 所有接口用同一个 Bearer token 保护（自签 App 里是明文，够用；有更高要求再上 mTLS）。
"""
import asyncio
import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field

import config
import push
import sources
from bypass import Engine
from store import Store
from translate import Translator

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)-5s %(name)s | %(message)s")
log = logging.getLogger("app")

store = Store(config.DB_PATH)
engine = Engine(max_conc=config.FETCH_CONCURRENCY)
tr = Translator(store)

inflight: set[str] = set()
_running = True


class DeviceIn(BaseModel):
    token: str = Field(min_length=32)
    env: str = "sandbox"
    sites: list[str] = ["bloomberg", "reuters"]
    realtime: bool = True
    quiet_from: int = 0
    quiet_to: int = 0


def auth(authorization: str = Header(default="")):
    if authorization != "Bearer " + config.API_TOKEN:
        raise HTTPException(status_code=401, detail="unauthorized")


async def process_one(rec: dict):
    key = rec["key"]
    if key in inflight:
        return
    inflight.add(key)
    try:
        raw = await engine.fetch(rec["url"])
        blocks = raw.get("blocks") or []
        if len(blocks) < 3:
            await store.mark_failed(key, "blocks_short:%d" % len(blocks))
            return

        raw["published_ts"] = rec.get("published_ts")
        art = await tr.article(raw)
        aid = await store.save_article(key, art)
        await store.mark_done(key, aid)

        # 首发保护 + 静默时段
        age = None
        if rec.get("published_ts"):
            age = int(time.time()) - rec["published_ts"]
        if age is not None and age > config.MAX_PUSH_AGE_SECONDS:
            log.info("skip push (age %ss): %s", age, art["title_zh"][:40])
            return

        for d in await store.devices_for(rec["site"], rec.get("published_ts")):
            if await store.already_pushed(d["token"], aid):
                continue
            ok = await push.send_to_device(
                store, d, article_id=aid, title=art["title_zh"],
                body="；".join(art.get("brief") or []) or art["title_zh"],
                site=rec["site"], url=rec["url"])
            if ok:
                await store.mark_pushed(d["token"], aid)
        log.info("done %s | %s", aid, art["title_zh"][:50])
    except Exception as e:
        log.exception("process failed: %s", rec["url"])
        await store.mark_failed(key, "%s: %s" % (type(e).__name__, e))
    finally:
        inflight.discard(key)


async def poller():
    log.info("poller started, interval=%ss", config.POLL_SECONDS)
    while _running:
        try:
            fresh = await sources.poll(store)
            if fresh:
                log.info("round: %d new", len(fresh))
            for rec in fresh:
                asyncio.create_task(process_one(rec))
        except Exception:
            log.exception("poll round failed")
        await asyncio.sleep(config.POLL_SECONDS)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await store.init()
    task = asyncio.create_task(poller())
    log.info("server up | db=%s", config.DB_PATH)
    yield
    global _running
    _running = False
    task.cancel()
    await engine.close()
    await tr.close()
    await store.close()


app = FastAPI(title="BPC News", version="1.0.0", lifespan=lifespan)


@app.get("/healthz")
async def healthz():
    return {"ok": True, "ts": int(time.time())}


@app.post("/v1/device")
async def register_device(d: DeviceIn, authorization: str = Header(default="")):
    auth(authorization)
    await store.upsert_device(d.token, d.env, d.sites, d.quiet_from, d.quiet_to, d.realtime)
    return {"ok": True, "env": d.env, "sites": d.sites}


@app.get("/v1/feed")
async def feed(limit: int = Query(60, ge=1, le=200),
               site: str | None = None, after: int = 0,
               authorization: str = Header(default="")):
    auth(authorization)
    return await store.feed(limit, site, after)


@app.get("/v1/article/{aid}")
async def article(aid: str, authorization: str = Header(default="")):
    auth(authorization)
    a = await store.article(aid)
    if not a:
        raise HTTPException(404, "not found")
    return a


@app.post("/v1/scan")
async def scan_now(authorization: str = Header(default="")):
    """手动触发一轮采集（调试用）"""
    auth(authorization)
    fresh = await sources.poll(store)
    for rec in fresh:
        asyncio.create_task(process_one(rec))
    return {"new": len(fresh)}


@app.post("/v1/testpush")
async def testpush(token: str, env: str = "sandbox",
                   authorization: str = Header(default="")):
    auth(authorization)
    code, reason = await push.send(
        token, env, article_id="test", title="测试推送 · 链路打通",
        body="BPC 服务端 -> APNs -> iPhone", site="bloomberg",
        url="https://www.bloomberg.com/")
    return {"status": code, "reason": reason, "apns_host": push.host_for(env)}


@app.get("/v1/stats")
async def stats(authorization: str = Header(default="")):
    auth(authorization)
    s = await store.stats()
    s["inflight"] = len(inflight)
    s["poll_seconds"] = config.POLL_SECONDS
    return s


@app.get("/v1/pending")
async def pending(authorization: str = Header(default="")):
    auth(authorization)
    rows = await store.pending(20)
    return [{k: r[k] for k in ("key", "site", "title", "status", "reason")} for r in rows]
