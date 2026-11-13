#!/usr/bin/env python3
"""离线验证内置词典的替换效果（不依赖 Swift 运行环境）。

做法：从 ios/BPCNews/Dict.swift 里抽出 (英文, 中文) 词条，
用与 Swift 端相同的算法（按长度倒序、\b 词边界、忽略大小写）替换真实标题，
用来判断「默认中文」在真新闻上到底能读成什么样。

用法：python ios/tools/check_dict.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

DICT_SWIFT = Path(__file__).resolve().parents[1] / "BPCNews" / "Dict.swift"

# 抓取到的真实彭博/路透标题（来自 news.google.com RSS）
HEADLINES = [
    "US Stocks Drift Before Inflation Test of Fed Bets: Markets Wrap",
    "Microsoft Races to Fix Outlook in One of Its Longest Outages",
    "European Shares Pull Back From Record High After Four-Day Rally",
    "German Lawmakers Sign Off on Higher Borrowing, Spending for 2027",
    "The US Job Market Narrative Shifts Toward Inflationary Risks",
    "Nvidia CEO Huang's Fall Threatens US-China Diplomacy",
    "Private Credit and Stablecoins Pose Risks Beyond Size, Bailey Warns",
    "OPEC+ Holds Output Cuts as Brent Crude Rebounds Above $78",
]


def load_pairs() -> list[tuple[str, str]]:
    text = DICT_SWIFT.read_text(encoding="utf-8")
    pairs = re.findall(r'\("([^"]+)",\s*"([^"]+)"\)', text)
    # 去掉注释里可能出现的示例
    out = []
    for en, zh in pairs:
        if not en or not zh or en.startswith("http"):
            continue
        out.append((en, zh))
    # 按英文长度倒序，长词优先
    out.sort(key=lambda p: len(p[0]), reverse=True)
    return out


def translate(text: str, pairs: list[tuple[str, str]]) -> str:
    for en, zh in pairs:
        text = re.sub(r"\b" + re.escape(en) + r"\b", zh, text, flags=re.IGNORECASE)
    return text


def main() -> int:
    if not DICT_SWIFT.exists():
        print("!! 找不到", DICT_SWIFT)
        return 2
    pairs = load_pairs()
    print(f"词条数: {len(pairs)}\n")

    hit_total = 0
    for h in HEADLINES:
        out = translate(h, pairs)
        # 统计命中：中文占比
        zh_chars = len(re.findall(r"[\u4e00-\u9fff]", out))
        ratio = zh_chars / max(1, len(out))
        hit_total += 1 if ratio > 0.25 else 0
        print(f"EN : {h}")
        print(f"ZH : {out}")
        print(f"     中文字符占比 {ratio:.0%}\n")

    print(f"结果: {hit_total}/{len(HEADLINES)} 条标题中文化程度 >25%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
