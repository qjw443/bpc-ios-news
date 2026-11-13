from __future__ import annotations
"""存储层：SQLite(aiosqlite)。所有写操作幂等，靠主键/唯一键去重。"""
import json
import time
import hashlib
from datetime import datetime
from typing import Any

import aiosqlite

import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS seen(
  key TEXT PRIMARY KEY,
  site TEXT, url TEXT, title TEXT,
  published_ts INTEGER, first_seen INTEGER, lag INTEGER,
  status TEXT DEFAULT 'pending',   -- pending|done|failed
  reason TEXT DEFAULT '', article_id TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS articles(
  id TEXT PRIMARY KEY,
  key TEXT UNIQUE,
  site TEXT, url TEXT,
  title TEXT, title_zh TEXT,
  brief TEXT,                       -- json array
  audio TEXT, blocks TEXT,          -- json array
  published_ts INTEGER, created_ts INTEGER
);
CREATE TABLE IF NOT EXISTS devices(
  token TEXT PRIMARY KEY,
  env TEXT DEFAULT 'sandbox',       -- sandbox|production
  sites TEXT DEFAULT '["bloomberg","reuters"]',
  quiet_from INTEGER DEFAULT 0,
  quiet_to INTEGER DEFAULT 0,
  realtime INTEGER DEFAULT 1,
  push_ok INTEGER DEFAULT 1,
  updated_ts INTEGER
);
CREATE TABLE IF NOT EXISTS pushed(
  device TEXT, article_id TEXT, ts INTEGER,
  PRIMARY KEY(device, article_id)
);
CREATE TABLE IF NOT EXISTS tr_cache(h TEXT PRIMARY KEY, zh TEXT, ts INTEGER);
CREATE INDEX IF NOT EXISTS idx_seen_status ON seen(status);
CREATE INDEX IF NOT EXISTS idx_art_ts ON articles(created_ts DESC);
"""


class Store:
    def __init__(self, path: str):
        self.path = path
        self.db: aiosqlite.Connection | None = None

    # ---------- lifecycle ----------
    async def init(self):
        self.db = await aiosqlite.connect(self.path)
        self.db.row_factory = aiosqlite.Row
        await self.db.executescript(SCHEMA)
        await self.db.commit()

    async def close(self):
        if self.db:
            await self.db.close()

    # ---------- 采集去重 ----------
    async def exists(self, key: str) -> bool:
        cur = await self.db.execute("SELECT 1 FROM seen WHERE key=?", (key,))
        return await cur.fetchone() is not None

    async def insert_pending(self, rec: dict):
        await self.db.execute(
            """INSERT OR IGNORE INTO seen(key,site,url,title,published_ts,first_seen,lag,status)
               VALUES(?,?,?,?,?,?,?,'pending')""",
            (rec["key"], rec["site"], rec["url"], rec["title"],
             rec.get("published_ts"), rec["first_seen"], rec.get("lag")))
        await self.db.commit()

    async def pending(self, limit: int = 50) -> list[dict]:
        cur = await self.db.execute(
            "SELECT * FROM seen WHERE status='pending' ORDER BY first_seen LIMIT ?", (limit,))
        rows = await cur.fetchall()
        return [dict(r) for r in rows]

    async def mark_failed(self, key: str, reason: str):
        await self.db.execute("UPDATE seen SET status='failed', reason=? WHERE key=?",
                              (reason[:500], key))
        await self.db.commit()

    async def mark_done(self, key: str, article_id: str = ""):
        await self.db.execute("UPDATE seen SET status='done', article_id=? WHERE key=?",
                              (article_id, key))
        await self.db.commit()

    # ---------- 文章 ----------
    @staticmethod
    def article_id(key: str) -> str:
        return hashlib.sha1(key.encode()).hexdigest()[:12]

    async def save_article(self, key: str, art: dict) -> str:
        aid = self.article_id(key)
        await self.db.execute(
            """INSERT OR REPLACE INTO articles
               (id,key,site,url,title,title_zh,brief,audio,blocks,published_ts,created_ts)
               VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
            (aid, key, art.get("site"), art.get("url"), art.get("title"),
             art.get("title_zh"), json.dumps(art.get("brief") or [], ensure_ascii=False),
             art.get("audio") or "", json.dumps(art.get("blocks") or [], ensure_ascii=False),
             art.get("published_ts"), int(time.time())))
        await self.db.commit()
        return aid

    async def article(self, aid: str) -> dict | None:
        cur = await self.db.execute("SELECT * FROM articles WHERE id=?", (aid,))
        r = await cur.fetchone()
        if not r:
            return None
        d = dict(r)
        d["brief"] = json.loads(d["brief"] or "[]")
        d["blocks"] = json.loads(d["blocks"] or "[]")
        return d

    async def feed(self, limit: int = 60, site: str | None = None, after: int = 0) -> list[dict]:
        sql = ("SELECT id,site,url,title,title_zh,brief,created_ts,published_ts "
               "FROM articles WHERE created_ts>=?")
        args: list[Any] = [after]
        if site:
            sql += " AND site=?"
            args.append(site)
        sql += " ORDER BY created_ts DESC LIMIT ?"
        args.append(limit)
        cur = await self.db.execute(sql, args)
        out = []
        for r in await cur.fetchall():
            out.append({
                "id": r["id"], "site": r["site"], "url": r["url"],
                "title": r["title"], "title_zh": r["title_zh"],
                "brief": json.loads(r["brief"] or "[]"),
                "ts": r["published_ts"] or r["created_ts"],
                "created_ts": r["created_ts"],
            })
        return out

    async def prune(self):
        cutoff = int(time.time()) - config.ARTICLE_TTL_DAYS * 86400
        await self.db.execute("DELETE FROM articles WHERE created_ts < ?", (cutoff,))
        await self.db.execute("DELETE FROM seen WHERE first_seen < ?", (cutoff,))
        await self.db.commit()

    # ---------- 设备 ----------
    async def upsert_device(self, token: str, env: str, sites: list[str],
                            quiet_from: int, quiet_to: int, realtime: bool):
        await self.db.execute(
            """INSERT INTO devices(token,env,sites,quiet_from,quiet_to,realtime,updated_ts)
               VALUES(?,?,?,?,?,?,?)
               ON CONFLICT(token) DO UPDATE SET
                 env=excluded.env, sites=excluded.sites,
                 quiet_from=excluded.quiet_from, quiet_to=excluded.quiet_to,
                 realtime=excluded.realtime, updated_ts=excluded.updated_ts""",
            (token, env, json.dumps(sites), quiet_from, quiet_to, 1 if realtime else 0,
             int(time.time())))
        await self.db.commit()

    async def delete_device(self, token: str):
        await self.db.execute("DELETE FROM devices WHERE token=?", (token,))
        await self.db.commit()

    async def all_devices(self) -> list[dict]:
        cur = await self.db.execute("SELECT * FROM devices")
        out = []
        for r in await cur.fetchall():
            d = dict(r)
            d["sites"] = json.loads(d["sites"] or "[]")
            out.append(d)
        return out

    async def devices_for(self, site: str, ts: int | None) -> list[dict]:
        """按站点 + 静默时段筛选需要推送的设备（逻辑集中在服务端，App 不做判断）"""
        hour = datetime.now().hour          # 容器时区由 TZ 环境变量控制
        out = []
        for d in await self.all_devices():
            if site not in d["sites"] or not d["push_ok"]:
                continue
            qf, qt = d["quiet_from"], d["quiet_to"]
            if qf != qt:
                quiet = (qf < qt and qf <= hour < qt) or (qf > qt and (hour >= qf or hour < qt))
                if quiet:
                    continue
            out.append(d)
        return out

    async def mark_pushed(self, token: str, aid: str):
        await self.db.execute("INSERT OR IGNORE INTO pushed(device,article_id,ts) VALUES(?,?,?)",
                              (token, aid, int(time.time())))
        await self.db.commit()

    async def already_pushed(self, token: str, aid: str) -> bool:
        cur = await self.db.execute(
            "SELECT 1 FROM pushed WHERE device=? AND article_id=?", (token, aid))
        return await cur.fetchone() is not None

    # ---------- 翻译缓存 ----------
    async def cache_get(self, h: str) -> str | None:
        cur = await self.db.execute("SELECT zh FROM tr_cache WHERE h=?", (h,))
        r = await cur.fetchone()
        return r["zh"] if r else None

    async def cache_put(self, h: str, zh: str):
        await self.db.execute("INSERT OR REPLACE INTO tr_cache(h,zh,ts) VALUES(?,?,?)",
                              (h, zh, int(time.time())))
        await self.db.commit()

    # ---------- 观测 ----------
    async def stats(self) -> dict:
        cur = await self.db.execute(
            "SELECT status, COUNT(*) c FROM seen GROUP BY status")
        seen = {r["status"]: r["c"] for r in await cur.fetchall()}
        cur = await self.db.execute("SELECT COUNT(*) c FROM articles")
        arts = (await cur.fetchone())["c"]
        cur = await self.db.execute("SELECT COUNT(*) c FROM devices")
        devs = (await cur.fetchone())["c"]
        cur = await self.db.execute(
            "SELECT AVG(lag) a FROM seen WHERE lag IS NOT NULL AND lag>=0 AND lag<7200")
        lag = (await cur.fetchone())["a"]
        return {"seen": seen, "articles": arts, "devices": devs,
                "avg_lag_seconds": round(lag, 1) if lag else None}
