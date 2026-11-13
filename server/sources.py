from __future__ import annotations
"""采集层：Google News RSS（实测 200 / 1~10 分钟延迟）+ 可选 sitemap 探针。

逻辑要点
1. 去重键 = sha1(规范化URL | 标题)，同一篇文章被多个源抓到只入库一次。
2. 只收「文章页」，过滤栏目页/合集页/视频页（Bloomberg Radio、栏目目录等噪音）。
3. 记录 lag = first_seen - published，用于衡量真实延迟，指导轮询频率。
4. Google News 的 CBMi... 跳转链接必须解析成真实文章 URL，否则抓取必失败。
"""
import re
import base64
import hashlib
import logging
import time

import httpx
import feedparser

log = logging.getLogger("sources")

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36")

# 主源：已实测可用
DISCOVERY_FEEDS = [
    ("bloomberg", "https://news.google.com/rss/search?q=site%3Abloomberg.com+when%3A2h"
                  "&hl=en-US&gl=US&ceid=US%3Aen"),
    ("reuters", "https://news.google.com/rss/search?q=site%3Areuters.com+when%3A2h"
                "&hl=en-US&gl=US&ceid=US%3Aen"),
]

# 加速源（直连 sitemap，当前需真浏览器指纹；验证通过后把 enabled 改 True）
PROBE_FEEDS = [
    {"site": "reuters", "enabled": False,
     "url": "https://www.reuters.com/arc/outboundfeeds/news-sitemap-index/?outputType=xml"},
    {"site": "bloomberg", "enabled": False,
     "url": "https://www.bloomberg.com/feeds/bbiz/sitemap_index.xml"},
]

# 文章页路径白名单：命中才认为是一篇文章
ARTICLE_PATHS = {
    "bloomberg": re.compile(r"bloomberg\.com/(news|opinion|features)/"
                            r"(articles|news|politics|business|markets|technology|"
                            r"green|wealth|economics|industries|pursuits)/20\d\d-"),
    "reuters": re.compile(r"reuters\.com/(world|business|markets|technology|legal|"
                          r"sustainability|breakingviews|graphics|sports|science|"
                          r"health|commentary|investigates)/"),
}


def normalize(url: str) -> str:
    url = url.split("?")[0].split("#")[0].rstrip("/")
    url = re.sub(r"^https?://(www\.)?", "", url)
    url = re.sub(r"/amp$", "", url)
    return url.lower()


def key_of(url: str, title: str) -> str:
    return hashlib.sha1((normalize(url) + "|" + title.strip().lower()).encode()).hexdigest()[:20]


def is_article(site: str, url: str) -> bool:
    pat = ARTICLE_PATHS.get(site)
    return bool(pat and pat.search(url))


async def resolve_google_link(client: httpx.AsyncClient, link: str) -> str:
    """Google News 跳转链接 -> 真实 URL。先试 base64 内嵌，再跟 302。"""
    if "news.google.com" not in link:
        return link
    try:
        gid = link.split("/articles/")[1].split("?")[0]
        raw = base64.urlsafe_b64decode(gid + "=" * (-len(gid) % 4))
        m = re.search(rb"https?://[\x20-\x7e]{10,}", raw)
        if m:
            cand = m.group().decode("utf-8", "ignore")
            if "bloomberg.com" in cand or "reuters.com" in cand:
                return cand
    except Exception:
        pass
    try:
        r = await client.get(link, follow_redirects=True)
        final = str(r.url)
        if "news.google.com" not in final:
            return final
    except Exception:
        pass
    return link


async def poll(store) -> list[dict]:
    """拉一轮，返回本轮新人（已写库，状态 pending）。"""
    fresh: list[dict] = []
    async with httpx.AsyncClient(timeout=25, headers={"User-Agent": UA},
                                 follow_redirects=True) as client:
        for site_hint, feed in DISCOVERY_FEEDS:
            try:
                r = await client.get(feed)
                if r.status_code != 200:
                    log.warning("feed %s -> HTTP %s", site_hint, r.status_code)
                    continue
            except Exception as e:
                log.warning("feed %s error: %s", site_hint, e)
                continue

            parsed = feedparser.parse(r.text)
            for it in parsed.entries:
                title = (it.get("title") or "").strip()
                if len(title) < 12:
                    continue
                url = await resolve_google_link(client, it.get("link", ""))
                if "bloomberg.com" in url:
                    site = "bloomberg"
                elif "reuters.com" in url:
                    site = "reuters"
                else:
                    continue
                if not is_article(site, url):
                    continue

                k = key_of(url, title)
                if await store.exists(k):
                    continue

                pub = it.get("published_parsed") or it.get("updated_parsed")
                pub_ts = int(time.mktime(pub)) if pub else None
                now = int(time.time())
                rec = {"key": k, "site": site, "url": url, "title": title,
                       "published_ts": pub_ts, "first_seen": now,
                       "lag": (now - pub_ts) if pub_ts else None}
                await store.insert_pending(rec)
                fresh.append(rec)
                log.info("NEW [%s] lag=%ss %s", site, rec["lag"], title[:80])

        # 加速源（默认关闭）
        for p in PROBE_FEEDS:
            if not p["enabled"]:
                continue
            try:
                r = await client.get(p["url"])
                if r.status_code != 200:
                    log.info("probe %s -> %s", p["site"], r.status_code)
                    continue
                for loc in re.findall(r"<loc>(.*?)</loc>", r.text):
                    if not is_article(p["site"], loc):
                        continue
                    k = key_of(loc, loc.rsplit("/", 1)[-1])
                    if await store.exists(k):
                        continue
                    rec = {"key": k, "site": p["site"], "url": loc,
                           "title": loc.rsplit("/", 1)[-1].replace("-", " "),
                           "published_ts": None, "first_seen": int(time.time()), "lag": None}
                    await store.insert_pending(rec)
                    fresh.append(rec)
            except Exception as e:
                log.warning("probe %s error: %s", p["site"], e)

    return fresh
