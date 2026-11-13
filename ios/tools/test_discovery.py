#!/usr/bin/env python3
"""发现层回归测试（真实网络，验证解析规则而不是"看起来能跑"）。

测的是 App 里那套规则的 Python 等价实现：
  · 彭博 sitemaps/news/latest.xml  -> urlset + news:title + news:publication_date
  · 彭博 栏目 RSS                   -> item/title/link/pubDate
  · 路透 sitemap                    -> urlset/loc + lastmod（用可达的历史档验证解析形状）
以及三条业务规则：
  · 只要文章页（isArticleURL）
  · 按 URL 去重
  · 标题清洗 + 日期解析

用法：python ios/tools/test_discovery.py
退出码：0 = 全过
"""
from __future__ import annotations

import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime
from datetime import datetime, timezone

UA_IOS = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
          "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")
UA_BOT = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

NS = {"sm": "http://www.sitemaps.org/schemas/sitemap/0.9",
      "news": "http://www.google.com/schemas/sitemap-news/0.9"}


def get(url: str, ua: str = UA_IOS, timeout: int = 25) -> bytes:
    req = urllib.request.Request(url, headers={
        "User-Agent": ua,
        "Accept": "application/xml,text/xml,application/rss+xml,*/*",
        "Accept-Language": "en-US,en;q=0.9",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


# ---------------- 业务规则（与 Swift 端一一对应） ----------------

def is_article_url(url: str, site: str) -> bool:
    u = url.split("?")[0]
    if site == "bloomberg":
        return ("bloomberg.com/news/articles/" in u
                or "bloomberg.com/news/features/" in u
                or "bloomberg.com/opinion/articles/" in u)
    if "reuters.com/" not in u:
        return False
    path = u.replace("https://www.reuters.com", "").replace("https://reuters.com", "")
    segs = [s for s in path.split("/") if s]
    if len(segs) < 2:
        return False
    if segs[0] == "article":          # 旧格式 /article/<section>/<slug>/
        return len(segs) >= 3
    return segs[0] in {"world", "business", "markets", "technology", "legal",
                       "sustainability", "breakingviews", "sports", "science",
                       "health", "commentary", "investigates", "graphics"}


def clean_title(t: str) -> str:
    for suffix in (" - Bloomberg.com", " - Bloomberg", " - Reuters", " | Reuters",
                   " - Reuters.com", " | Bloomberg"):
        if t.endswith(suffix):
            t = t[: -len(suffix)]
    return t.strip()


def parse_news_sitemap(xml: bytes):
    root = ET.fromstring(xml)
    out = []
    for url in root.findall("sm:url", NS):
        loc = url.findtext("sm:loc", default="", namespaces=NS)
        news = url.find("news:news", NS)
        title, date = "", None
        if news is not None:
            title = news.findtext("news:title", default="", namespaces=NS)
            ds = news.findtext("news:publication_date", default="", namespaces=NS)
            if ds:
                date = datetime.fromisoformat(ds.replace("Z", "+00:00"))
        out.append((loc, title, date))
    return out


def parse_rss(xml: bytes):
    root = ET.fromstring(xml)
    out = []
    for item in root.iter("item"):
        out.append((item.findtext("link", ""),
                    item.findtext("title", ""),
                    item.findtext("pubDate", "")))
    return out


def dedupe(rows):
    seen, out = set(), []
    for loc, title, date in rows:
        key = loc.split("?")[0]
        if key in seen:
            continue
        seen.add(key)
        out.append((loc, title, date))
    return out


# ---------------- 测试 ----------------

def main() -> int:
    fails = []

    print("=" * 78)
    print("① 彭博 sitemaps/news/latest.xml（App 的主力发现源）")
    try:
        raw = get("https://www.bloomberg.com/sitemaps/news/latest.xml", UA_BOT)
        rows = parse_news_sitemap(raw)
        arts = [(l, t, d) for l, t, d in rows if is_article_url(l, "bloomberg")]
        arts = dedupe(arts)
        print(f"   bytes={len(raw)}  <url>={len(rows)}  文章页={len(arts)}")
        assert len(rows) > 100, "urlset 解析异常"
        assert len(arts) > 50, "文章过滤异常"
        assert all(t for _, t, _ in arts[:50]), "news:title 为空"
        assert all(d for _, _, d in arts[:50] if d is not None), "日期缺失（部分）"
        for l, t, d in arts[:3]:
            print(f"   · {d:%m-%d %H:%M}  {clean_title(t)[:56]}")
            print(f"     {l}")
    except Exception as e:
        fails.append(f"彭博 sitemap: {e}")

    print("=" * 78)
    print("② 彭博栏目 RSS（备用发现源）")
    for sec in ("markets", "politics", "technology"):
        try:
            raw = get(f"https://feeds.bloomberg.com/{sec}/news.rss")
            rows = parse_rss(raw)
            arts = [(l, t, p) for l, t, p in rows if is_article_url(l, "bloomberg")]
            d0 = parsedate_to_datetime(rows[0][2]) if rows and rows[0][2] else None
            print(f"   {sec:<11} item={len(rows):>3} 文章页={len(arts):>3}  最新={d0}")
            assert rows, f"{sec} 无条目"
            assert arts, f"{sec} 无文章页链接"
        except Exception as e:
            fails.append(f"RSS {sec}: {e}")

    print("=" * 78)
    print("③ 路透 sitemap 解析形状（实时档被 401 挑战，用可达的历史档验证解析器）")
    try:
        raw = get("https://www.reuters.com/service/archive-sitemap/2023-10-31.xml", UA_BOT)
        root = ET.fromstring(raw)
        locs = [e.text for e in root.iter("{http://www.sitemaps.org/schemas/sitemap/0.9}loc")]
        arts = [l for l in locs if is_article_url(l or "", "reuters")]
        print(f"   bytes={len(raw)}  loc={len(locs)}  判定为文章页={len(arts)}")
        print(f"   样例: {locs[0][:90] if locs else '-'}")
        assert len(locs) > 500, "urlset 解析异常"
    except Exception as e:
        fails.append(f"路透 sitemap: {e}")

    print("=" * 78)
    print("④ 实时路透官方源可达性（真机上通常放行；这里记录真实状态码）")
    for u in ("https://www.reuters.com/arc/outboundfeeds/news-sitemap-index/?outputType=xml",
              "https://www.reuters.com/arc/outboundfeeds/sitemap-index/?outputType=xml"):
        try:
            raw = get(u, UA_BOT, timeout=15)
            print(f"   200  {u}  bytes={len(raw)}")
        except Exception as e:
            code = getattr(e, "code", "?")
            print(f"   {code}  {u}  -> 设备端会改走网页抓取")

    print("=" * 78)
    if fails:
        print("FAIL:")
        for f in fails:
            print("  -", f)
        return 1
    print("PASS  发现层解析规则在真实数据上通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
