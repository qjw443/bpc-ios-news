from __future__ import annotations
"""BPC 引擎（Playwright + 反检测）：把 Chrome 扩展的规则搬到服务端。

对应关系（BPC -> 本文件）
  block_regex / declarativeNetRequest  ->  route.abort()
  modifyHeaders(UA/Referer/Cookie)     ->  stealth 的「自洽头集合」+ clear_cookies()
  remove_cookies_fn()                  ->  clear_cookies() + localStorage.clear()
  cs_code (hide_elem / rm_class)       ->  cleanup_js + inject_css
  ld_json / __NEXT_DATA__              ->  extract.kind == next_data
  ld_archive_is                        ->  _archive_fallback()

反检测（本文件的核心增量）
  · 每个请求带一套自洽指纹（UA ↔ UA-CH ↔ 视口 ↔ 时区 ↔ WebGL），发请求前 validate()
  · 两种模式：browser（真 Chrome 指纹）/ bot（Googlebot 极简头），按规则顺序尝试
  · 被 Cloudflare/DataDome/HUMAN/Akamai 拦了就换模式、换代理、退避，不硬撞
  · 真人阅读模拟：贝塞尔鼠标 + 分段滚动 + 与篇幅相关的停顿
"""
import asyncio
import hashlib
import logging
import os
import random
import re
from pathlib import Path

import yaml
from playwright.async_api import async_playwright, Browser, BrowserContext

import stealth

log = logging.getLogger("bypass")

RULES_DIR = Path(__file__).resolve().parent / "rules"
RULES: dict[str, dict] = {}


def load_rules() -> None:
    RULES.clear()
    for p in RULES_DIR.glob("*.yaml"):
        RULES[p.stem] = yaml.safe_load(p.read_text(encoding="utf-8"))


load_rules()


class BlockedError(RuntimeError):
    def __init__(self, kind: str, mode: str, url: str):
        self.kind = kind
        self.mode = mode
        self.url = url
        super().__init__("blocked by %s (mode=%s) %s" % (kind, mode, url))


NEXT_DATA_JS = r"""
(cfg) => {
  const el = document.querySelector('script#__NEXT_DATA__');
  if (!el) return null;
  let j;
  try { j = JSON.parse(el.textContent); } catch (e) { return null; }
  let n = j;
  for (const k of cfg.container.split('.')) { n = n ? n[k] : null; }
  if (!n) return null;

  const txt = (it) => {
    if (!it) return '';
    if (it.type === 'text') return it.value || '';
    if (it.type === 'entity') return (it.data && (it.data.text || it.data.value)) || '';
    if (it.type === 'link') {
      const t = (it.content || []).map(txt).join('');
      let h = (it.data && it.data.href) || '';
      if (h.indexOf('bbg://securities/') === 0) {
        const s = h.split('bbg://securities/')[1];
        const path = /\d+[A-Z]%20[A-Z]{2}%20Equity/.test(s) ? '/profile/company/' : '/quote/';
        h = 'https://www.bloomberg.com' + path + s;
      }
      return t ? '<a href="' + h + '">' + t + '</a>' : '';
    }
    if (it.content) return it.content.map(txt).join('');
    return '';
  };

  const blocks = [];
  for (const p of (n.body && n.body.content) || []) {
    const t = p.type || '';
    if (t === 'paragraph' || t === 'heading') {
      const s = txt(p).trim();
      if (s) blocks.push({type: t === 'heading' ? 'h2' : 'p', text: s});
    } else if (t === 'hr') {
      blocks.push({type: 'hr', text: ''});
    } else if (t.endsWith('quote')) {
      const s = (p.content || []).map(c => txt(c)).join(' ').trim();
      if (s) blocks.push({type: 'quote', text: s});
    } else if (t === 'list') {
      (p.content || []).forEach(li => {
        const s = txt(li).trim();
        if (s) blocks.push({type: 'li', text: s});
      });
    } else if (t === 'media' && p.data && p.data.image && p.data.image.url) {
      blocks.push({type: 'img', text: (p.data.image.caption || ''), src: p.data.image.url});
    }
  }
  return {
    title: n.headline || '',
    summary: (n.aiSummary && n.aiSummary.text) || [],
    audio: n.readingUrl || '',
    blocks: blocks
  };
}
"""

DOM_EXTRACT_JS = r"""
(cfg) => {
  const one = (s) => { try { return document.querySelector(s); } catch (e) { return null; } };
  const root = one(cfg.article_selector) || document.body;
  const nodes = cfg.paragraph_selector
      ? Array.from(document.querySelectorAll(cfg.paragraph_selector))
      : Array.from(root.querySelectorAll('p'));
  const blocks = [];
  for (const p of nodes) {
    const t = (p.innerText || '').replace(/\s+\n/g, '\n').trim();
    if (t.length > 1 && !/^(advertisement|read more|sign up)/i.test(t)) {
      blocks.push({type: 'p', text: t});
    }
  }
  const h1 = one(cfg.title_selector);
  return {
    title: ((h1 && h1.innerText) || document.title || '').trim(),
    summary: [], audio: '', blocks: blocks
  };
}
"""


class Engine:
    def __init__(self, max_conc: int = 2, headless: bool = True):
        self._pw = None
        self._browser: Browser | None = None
        self._sem = asyncio.Semaphore(max_conc)
        self._lock = asyncio.Lock()
        self._persistent: dict[str, BrowserContext] = {}
        self.headless = headless
        self.channel = os.getenv("PW_CHANNEL", "chromium")
        self.proxy = stealth.proxy_from_env()
        self.user_data_root = os.getenv("PW_USER_DATA_DIR", "")

    # ---------------- 浏览器 ----------------

    async def _ensure(self) -> Browser:
        async with self._lock:
            if self._browser is None or not self._browser.is_connected():
                self._pw = await async_playwright().start()
                args = [
                    "--disable-blink-features=AutomationControlled",
                    "--no-sandbox", "--disable-dev-shm-usage",
                    "--disable-features=IsolateOrigins,site-per-process",
                    "--no-default-browser-check", "--no-first-run",
                    "--disable-infobars", "--metrics-recording-only",
                ]
                launched = None
                for ch in [self.channel, "chrome", "chromium", None]:
                    try:
                        kw = {"headless": self.headless, "args": args}
                        if ch:
                            kw["channel"] = ch
                        launched = await self._pw.chromium.launch(**kw)
                        log.info("browser launched (channel=%s)", ch or "default")
                        break
                    except Exception as e:
                        log.info("launch channel=%s failed: %s", ch, str(e)[:80])
                if launched is None:
                    raise RuntimeError("no chromium channel available")
                self._browser = launched
            return self._browser

    @staticmethod
    def rule_for(url: str) -> tuple[str, dict]:
        host = re.sub(r"^https?://", "", url).split("/")[0].replace("www.", "").lower()
        for name, r in RULES.items():
            for h in r.get("hosts", []):
                base = h.replace("www.", "").lower()
                if host == base or host.endswith("." + base):
                    return name, r
        raise ValueError("no rule for " + url)

    # ---------------- 上下文（指纹装配） ----------------

    def _context_kwargs(self, rule: dict, mode: str) -> dict:
        profile = stealth.pick_profile(rule.get("profile"))
        referer = rule.get("referer") or None

        if mode == "bot":
            kind = rule.get("bot_kind", "googlebot")
            headers = stealth.bot_headers(kind, referer)
            bad = stealth.validate(headers["User-Agent"], headers)
            if bad:
                raise RuntimeError("bot 头自检失败: %s" % bad)
            return {
                "user_agent": headers["User-Agent"],
                "extra_http_headers": headers,
                "viewport": profile["viewport"],
                "locale": "en-US",
                "timezone_id": profile["timezone"],
                "java_script_enabled": True,
                "device_scale_factor": 1,
                "is_mobile": False,
                "has_touch": False,
                "ignore_https_errors": False,
                "_profile": profile,
                "_mode": mode,
            }

        headers = stealth.browser_headers(profile, referer)
        bad = stealth.validate(profile["ua"], headers)
        if bad:
            raise RuntimeError("浏览器头自检失败: %s" % bad)
        kw = {
            "user_agent": profile["ua"],
            "extra_http_headers": headers,
            "viewport": profile["viewport"],
            "screen": profile.get("screen"),
            "locale": profile["locale"],
            "timezone_id": profile["timezone"],
            "color_scheme": "dark",
            "device_scale_factor": 1,
            "is_mobile": False,
            "has_touch": False,
            "java_script_enabled": True,
            "_profile": profile,
            "_mode": mode,
        }
        if self.proxy:
            kw["proxy"] = self.proxy
        return kw

    async def _make_context(self, site: str, rule: dict, mode: str) -> tuple[BrowserContext, bool]:
        kw = self._context_kwargs(rule, mode)
        kw.pop("_profile", None)
        kw.pop("_mode", None)

        # 需要「暖 cookie」且配置了用户目录时，走持久化上下文（更像真实老访客）
        if (not rule.get("clear_cookies")) and self.user_data_root:
            key = "%s_%s" % (site, mode)
            if key not in self._persistent:
                path = Path(self.user_data_root) / key
                path.mkdir(parents=True, exist_ok=True)
                browser = await self._ensure()
                self._persistent[key] = await browser.new_context(**kw)
                log.info("persistent context ready: %s", path)
            return self._persistent[key], False

        browser = await self._ensure()
        ctx = await browser.new_context(**kw)
        return ctx, True

    # ---------------- 主流程 ----------------

    async def fetch(self, url: str, mode: str | None = None) -> dict:
        site, rule = self.rule_for(url)
        modes = [mode] if mode else list(rule.get("modes") or ["browser"])
        last: Exception | None = None
        for m in modes:
            try:
                return await self._attempt(url, site, rule, m)
            except BlockedError as e:
                log.warning("mode=%s blocked by %s -> next mode", m, e.kind)
                last = e
                await asyncio.sleep(random.uniform(1.5, 3.5))
            except Exception as e:
                log.warning("mode=%s failed: %s", m, e)
                last = e
        if last:
            raise last
        raise RuntimeError("fetch failed: " + url)

    async def _attempt(self, url: str, site: str, rule: dict, mode: str) -> dict:
        async with self._sem:
            ctx, ephemeral = await self._make_context(site, rule, mode)
            page = None
            try:
                if mode != "bot":
                    profile = stealth.pick_profile(rule.get("profile"))
                    await ctx.add_init_script(stealth.stealth_script(profile))

                if rule.get("clear_cookies"):
                    await ctx.clear_cookies()
                    await ctx.add_init_script(
                        "try{localStorage.clear();sessionStorage.clear();}catch(e){}")

                pats = [re.compile(p) for p in (rule.get("block_urls") or [])]
                drop = set(rule.get("block_resource_types") or [])

                async def route_handler(route):
                    req = route.request
                    try:
                        if req.resource_type in drop or any(p.search(req.url) for p in pats):
                            await route.abort()
                        else:
                            await route.continue_()
                    except Exception:
                        try:
                            await route.continue_()
                        except Exception:
                            pass

                await ctx.route("**/*", route_handler)
                page = await ctx.new_page()
                await page.route("**/*", route_handler)
                page.on("dialog", lambda d: asyncio.ensure_future(d.dismiss()))

                resp = await page.goto(url, wait_until="domcontentloaded",
                                       timeout=45000, referer=rule.get("referer") or None)
                status = resp.status if resp else 0

                if rule.get("human") and mode != "bot":
                    await stealth.human_read(page, float(rule.get("human_intensity", 1.0)))

                if rule.get("wait_selector"):
                    try:
                        await page.wait_for_selector(rule["wait_selector"], timeout=12000)
                    except Exception:
                        log.info("wait_selector miss: %s", url)

                html_now = ""
                try:
                    html_now = await page.content()
                except Exception:
                    pass

                blocked = stealth.detect_block(status, html_now)
                if blocked:
                    raise BlockedError(blocked, mode, url)

                if rule.get("inject_css"):
                    await page.add_style_tag(content=rule["inject_css"])
                if rule.get("cleanup_js"):
                    await page.evaluate(rule["cleanup_js"])
                await page.wait_for_timeout(random.randint(350, 900))

                ex = rule["extract"]
                data = await page.evaluate(
                    NEXT_DATA_JS if ex["kind"] == "next_data" else DOM_EXTRACT_JS, ex)

                plain = " ".join((b.get("text") or "") for b in (data or {}).get("blocks", []))
                if not data or len(data.get("blocks") or []) < 3 or \
                        stealth.detect_paywall_text(plain):
                    log.info("paywall residual, archive fallback: %s", url)
                    alt = await self._archive_fallback(ctx, url, rule)
                    if alt and len(alt.get("blocks") or []) > len((data or {}).get("blocks") or []):
                        data = alt

                data = data or {"title": "", "summary": [], "audio": "", "blocks": []}
                blocks = [b for b in data.get("blocks") or [] if (b.get("text") or b.get("src"))]
                data["blocks"] = blocks
                data["site"] = site
                data["url"] = url
                data["mode"] = mode
                data["residual_wall"] = stealth.detect_paywall_text(
                    " ".join(b.get("text") or "" for b in blocks))
                data["hash"] = hashlib.sha256(
                    ("\n".join(b.get("text") or "" for b in blocks)).encode()
                ).hexdigest()[:16]
                return data
            finally:
                if page:
                    try:
                        await page.close()
                    except Exception:
                        pass
                if ephemeral:
                    try:
                        await ctx.close()
                    except Exception:
                        pass

    async def _archive_fallback(self, ctx: BrowserContext, url: str,
                                rule: dict) -> dict | None:
        page = None
        try:
            page = await ctx.new_page()
            await page.goto("https://archive.ph/newest/" + url,
                            wait_until="domcontentloaded", timeout=30000)
            return await page.evaluate(r"""
              () => {
                const box = document.querySelector('div.TEXT-BLOCK, article, #CONTENT, div.post-content');
                if (!box) return null;
                const blocks = Array.from(box.querySelectorAll('p, h2, h3'))
                  .map(p => ({type: /^H/.test(p.tagName) ? 'h2' : 'p',
                              text: (p.innerText || '').trim()}))
                  .filter(b => b.text.length > 1);
                return {title: document.title.replace(/\s*[-|]\s*archive.*$/i, ''),
                        summary: [], audio: '', blocks: blocks, from_archive: true};
              }
            """)
        except Exception as e:
            log.info("archive fallback failed: %s", e)
            return None
        finally:
            if page:
                try:
                    await page.close()
                except Exception:
                    pass

    async def close(self):
        for ctx in self._persistent.values():
            try:
                await ctx.close()
            except Exception:
                pass
        self._persistent.clear()
        try:
            if self._browser:
                await self._browser.close()
        finally:
            if self._pw:
                await self._pw.stop()
