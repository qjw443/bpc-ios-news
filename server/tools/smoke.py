from __future__ import annotations
"""离线自检：不联网也能验证流水线各阶段的数据结构是否正确。

用法：
    python tools/smoke.py --url https://www.bloomberg.com/news/articles/...
    python tools/smoke.py --rules            # 只检查规则文件可解析
"""
import argparse
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import yaml  # noqa: E402


def check_rules() -> int:
    bad = 0
    for p in (Path(__file__).resolve().parents[1] / "rules").glob("*.yaml"):
        try:
            d = yaml.safe_load(p.read_text(encoding="utf-8"))
            assert d.get("hosts"), "缺少 hosts"
            assert d.get("extract", {}).get("kind") in ("next_data", "dom"), "extract.kind 非法"
            print("[ok] %-12s hosts=%s kind=%s" % (p.stem, d["hosts"], d["extract"]["kind"]))
        except Exception as e:
            bad += 1
            print("[FAIL] %s -> %s" % (p.name, e))
    return bad


async def check_fetch(url: str) -> int:
    from bypass import Engine
    e = Engine(max_conc=1, headless=True)
    try:
        data = await e.fetch(url)
        blocks = data.get("blocks") or []
        print("site        :", data.get("site"))
        print("mode        :", data.get("mode"))
        print("title       :", data.get("title"))
        print("audio       :", data.get("audio") or "-")
        print("blocks      :", len(blocks))
        print("residualWall:", data.get("residual_wall"))
        for b in blocks[:3]:
            print("  -", b["type"], "|", (b.get("text") or "")[:100])
        ok = len(blocks) >= 3 and not data.get("residual_wall")
        print("\nRESULT:", "PASS" if ok else "FAIL")
        print("raw json ->", json.dumps(data, ensure_ascii=False)[:400])
        return 0 if ok else 2
    finally:
        await e.close()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--rules", action="store_true")
    ap.add_argument("--url")
    a = ap.parse_args()
    if a.rules or not a.url:
        sys.exit(check_rules())
    sys.exit(asyncio.run(check_fetch(a.url)))
