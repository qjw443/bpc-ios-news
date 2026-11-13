#!/usr/bin/env python3
"""校验 Rules.swift 里的 WKContentRuleList JSON 是否合法。

为什么必须离线校验：规则编译发生在 App 运行时，
JSON 里一个多余的逗号/转义错误，`compileContentRuleList` 就会失败，
表现是「付费墙没被拦住」——而且只在真机上才暴露，排查很慢。

用法：python ios/tools/check_rules.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "BPCNews" / "Rules.swift"


def extract_raw(_text: str, name: str) -> str | None:
    """抓 static let <name> = #\"\"\" ... \"\"\"# 之间的内容"""
    m = re.search(r'static let ' + name + r'\s*=\s*#"""\n(.*?)\n\s*"""#', _text, re.S)
    return m.group(1) if m else None


def main() -> int:
    if not SRC.exists():
        print("!! 找不到", SRC)
        return 2
    text = SRC.read_text(encoding="utf-8")
    bad = 0

    for name, site in (("blockBloomberg", "bloomberg"), ("blockReuters", "reuters")):
        raw = extract_raw(text, name)
        if raw is None:
            print(f"[FAIL] {name}: 没找到规则字符串")
            bad += 1
            continue
        try:
            rules = json.loads(raw)
        except Exception as e:
            print(f"[FAIL] {name}: JSON 不合法 -> {e}")
            bad += 1
            continue
        if not isinstance(rules, list) or not rules:
            print(f"[FAIL] {name}: 顶层必须是规则数组")
            bad += 1
            continue
        problems = []
        for i, r in enumerate(rules):
            trig = r.get("trigger", {})
            act = r.get("action", {})
            uf = trig.get("url-filter")
            if not uf:
                problems.append(f"#{i} 缺 trigger.url-filter")
            elif not uf.startswith(".*") or not uf.endswith(".*"):
                problems.append(f"#{i} url-filter 建议用 .* 包裹（{uf}）")
            if act.get("type") != "block":
                problems.append(f"#{i} action.type 不是 block")
            rt = trig.get("resource-type")
            if rt is not None and not set(rt) <= {"document", "image", "style-sheet", "script",
                                                  "font", "raw", "svg-document", "media", "popup"}:
                problems.append(f"#{i} resource-type 含非法值 {rt}")
            # 正则本身能不能编译
            try:
                re.compile(uf or "")
            except re.error as e:
                problems.append(f"#{i} 正则无法编译: {e}")
        if problems:
            print(f"[FAIL] {name}: {len(problems)} 处问题")
            for p in problems:
                print("        -", p)
            bad += 1
        else:
            print(f"[ok]   {name}: {len(rules)} 条规则，JSON 合法，正则可编译")

    # 清理脚本/提取脚本的括号配平（粗检）
    for name in ("cleanupJS", "extractBloomberg", "extractPaywalled", "extractArchive"):
        raw = extract_raw(text, name)
        if raw is None:
            # cleanupJS 用的是普通 """，单独处理
            m = re.search(r'static let ' + name + r'\s*=\s*"""\n(.*?)\n\s*"""', text, re.S)
            raw = m.group(1) if m else None
        if raw is None:
            print(f"[FAIL] {name}: 没找到脚本")
            bad += 1
            continue
        if raw.count("{") != raw.count("}") or raw.count("(") != raw.count(")"):
            print(f"[FAIL] {name}: 括号不配平 {{}}={raw.count('{')}/{raw.count('}')} ()={raw.count('(')}/{raw.count(')')}")
            bad += 1
        else:
            print(f"[ok]   {name}: 括号配平（{len(raw)} 字符）")

    print("\n结果:", "PASS" if bad == 0 else f"{bad} 项失败")
    return 0 if bad == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
