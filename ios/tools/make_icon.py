#!/usr/bin/env python3
"""生成 App 图标（Bloomberg 风：纯黑底 / 纸白衬线 B / 一枚信号橙）。

产物：
  ios/BPCNews/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
  ios/BPCNews/Assets.xcassets/AppIcon.appiconset/Contents.json
  ios/BPCNews/Assets.xcassets/Contents.json
用法：python ios/tools/make_icon.py
"""
from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

IOS = Path(__file__).resolve().parents[1]
ASSETS = IOS / "BPCNews" / "Assets.xcassets"
ICONSET = ASSETS / "AppIcon.appiconset"

SIZE = 1024
BLACK = (0, 0, 0)
INK = (245, 245, 244)
ORANGE = (255, 107, 0)
DIM = (139, 139, 143)
HAIR = (37, 37, 39)

SERIF_CANDIDATES = [
    r"C:\Windows\Fonts\georgiab.ttf",
    r"C:\Windows\Fonts\timesbd.ttf",
    r"C:\Windows\Fonts\constanb.ttf",
    r"C:\Windows\Fonts\cambriab.ttf",
]
SANS_CANDIDATES = [
    r"C:\Windows\Fonts\seguisb.ttf",
    r"C:\Windows\Fonts\arialbd.ttf",
]


def pick(cands: list[str]) -> str | None:
    for c in cands:
        if Path(c).exists():
            return c
    return None


def build(serif_path: str, sans_path: str | None) -> Image.Image:
    img = Image.new("RGB", (SIZE, SIZE), BLACK)
    d = ImageDraw.Draw(img)

    # 外圈发丝线（呼应 App 内的 hairline 设计语言）
    m = 58
    d.rectangle([m, m, SIZE - m - 1, SIZE - m - 1], outline=HAIR, width=2)

    # 衬线 B
    font = ImageFont.truetype(serif_path, 560)
    box = d.textbbox((0, 0), "B", font=font)
    w = box[2] - box[0]
    h = box[3] - box[1]
    x = (SIZE - w) / 2 - box[0]
    y = (SIZE - h) / 2 - box[1] - 46
    d.text((x, y), "B", font=font, fill=INK)

    # 信号橙横杠
    bar_w, bar_h = 224, 14
    d.rounded_rectangle(
        [SIZE / 2 - bar_w / 2, SIZE / 2 + 262, SIZE / 2 + bar_w / 2, SIZE / 2 + 262 + bar_h],
        radius=bar_h // 2, fill=ORANGE)

    # 底部小字（密排大写）
    if sans_path:
        f2 = ImageFont.truetype(sans_path, 40)
        label = "B L O O M B E R G  ·  R E U T E R S"
        b2 = d.textbbox((0, 0), label, font=f2)
        d.text(((SIZE - (b2[2] - b2[0])) / 2 - b2[0], SIZE - 196), label, font=f2, fill=DIM)

    return img


def main() -> int:
    serif = pick(SERIF_CANDIDATES)
    if not serif:
        print("!! 找不到衬线字体")
        return 2
    sans = pick(SANS_CANDIDATES)

    ICONSET.mkdir(parents=True, exist_ok=True)
    icon = build(serif, sans)
    icon.save(ICONSET / "AppIcon-1024.png", "PNG")

    (ICONSET / "Contents.json").write_text(json.dumps({
        "images": [{
            "filename": "AppIcon-1024.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }],
        "info": {"author": "xcode", "version": 1},
    }, indent=2, ensure_ascii=False), encoding="utf-8")

    (ASSETS / "Contents.json").write_text(json.dumps({
        "info": {"author": "xcode", "version": 1}
    }, indent=2), encoding="utf-8")

    # 便捷预览（贴在仓库里，方便直接用浏览器/看图工具打开）
    preview = IOS.parent / "design" / "icon-preview.png"
    preview.parent.mkdir(parents=True, exist_ok=True)
    icon.resize((512, 512), Image.LANCZOS).save(preview, "PNG")

    print(f"[ok] 字体: {serif}" + (f" / {sans}" if sans else " / (无小字)"))
    print(f"[ok] {ICONSET / 'AppIcon-1024.png'}")
    print(f"[ok] {ICONSET / 'Contents.json'}")
    print(f"[ok] {ASSETS / 'Contents.json'}")
    print(f"[ok] 预览: {preview}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
