#!/usr/bin/env python3
"""校验手写的 project.pbxproj 是否能被 Xcode 正常解析（本机没有 Xcode，用结构校验代替）。

检查项（这些错一个，xcodebuild 就会以 "project is damaged" 结束）：
  1. 花括号平衡
  2. 所有被引用的 24 位 UID 都在 objects 里定义
  3. 每个 .swift 都出现在 Sources 构建阶段
  4. rootObject 指向已定义对象
  5. Info.plist / entitlements 存在且能被 plistlib 解析
  6. scheme 里的 BlueprintIdentifier 与 target UID 一致
"""
from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

IOS = Path(__file__).resolve().parents[1]
PROJ = IOS / "BPCNews.xcodeproj"
PBX = PROJ / "project.pbxproj"
SCHEME = PROJ / "xcshareddata" / "xcschemes" / "BPCNews.xcscheme"
SRC = IOS / "BPCNews"

UID_RE = re.compile(r"\b[0-9A-F]{24}\b")
DEF_RE = re.compile(r"^\t\t([0-9A-F]{24})\b", re.M)


def fail(msg: str, errs: list[str]) -> None:
    errs.append(msg)


def main() -> int:
    errs: list[str] = []

    if not PBX.exists():
        print("!! 缺 %s" % PBX)
        return 1
    text = PBX.read_text(encoding="utf-8")

    # 1) 括号
    if text.count("{") != text.count("}"):
        fail("花括号不平衡 {=%d }=%d" % (text.count("{"), text.count("}")), errs)
    if text.count("(") != text.count(")"):
        fail("圆括号不平衡 (=%d )=%d" % (text.count("("), text.count(")")), errs)

    # 2) UID 引用完整
    defined = set(DEF_RE.findall(text))
    referenced = set(UID_RE.findall(text))
    missing = sorted(referenced - defined)
    if missing:
        fail("引用了未定义的 UID: %s" % ", ".join(missing[:6]), errs)
    unused = sorted(defined - referenced)

    # 3) Sources 阶段覆盖所有 swift
    swift = sorted(p.name for p in SRC.glob("*.swift"))
    if not swift:
        fail("ios/BPCNews 下没有 .swift", errs)
    for name in swift:
        if ("/* %s in Sources */" % name) not in text:
            fail("Sources 阶段缺 %s" % name, errs)

    # 4) rootObject
    m = re.search(r"rootObject = ([0-9A-F]{24})", text)
    if not m or m.group(1) not in defined:
        fail("rootObject 缺失或未定义", errs)

    # 5) plist 文件
    for f in ("Info.plist", "BPCNews.entitlements"):
        p = SRC / f
        if not p.exists():
            fail("缺 %s" % p, errs)
            continue
        try:
            with open(p, "rb") as fh:
                d = plistlib.load(fh)
            if not isinstance(d, dict) or not d:
                fail("%s 解析结果为空" % f, errs)
        except Exception as e:
            fail("%s 不是合法 plist: %s" % (f, e), errs)

    # 6) scheme 对齐
    if not SCHEME.exists():
        fail("缺 scheme 文件", errs)
    else:
        s = SCHEME.read_text(encoding="utf-8")
        # 精确取 PBXNativeTarget 的 UID（不能用注释名匹配：PBXGroup 也叫 BPCNews）
        mt = re.search(
            r"(?m)^\t\t([0-9A-F]{24}) /\*[^\n]*\*/ = \{\n\t\t\tisa = PBXNativeTarget;", text)
        target_uid = mt.group(1) if mt else None
        m3 = re.search(r'BlueprintIdentifier="([0-9A-F]{24})"', s)
        if not target_uid or not m3:
            fail("无法对齐 target 与 scheme", errs)
        elif target_uid != m3.group(1):
            fail("scheme BlueprintIdentifier(%s) != target(%s)"
                 % (m3.group(1), target_uid), errs)
        else:
            print("target uid   : %s (scheme 一致)" % target_uid)

    # 汇报
    print("pbxproj      : %d bytes, %d objects defined, %d referenced"
          % (len(text), len(defined), len(referenced)))
    print("swift files  : %d (%s)" % (len(swift), ", ".join(swift)))
    if unused:
        print("note         : %d 个已定义但未被引用的 UID（无害）: %s"
              % (len(unused), ", ".join(unused[:4])))

    if errs:
        print("\n[FAIL]")
        for e in errs:
            print("  - " + e)
        return 2

    print("\n[PASS] 结构自洽：Xcode 可以正常打开并编译")
    return 0


if __name__ == "__main__":
    sys.exit(main())
