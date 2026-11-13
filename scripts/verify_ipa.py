#!/usr/bin/env python3
"""IPA 验真：不只看 zip 结构，还解析 Mach-O 头，确认里面是「真 arm64 iOS 可执行文件」。

校验项
  1. Payload/<App>.app 结构完整（Info.plist + 可执行文件）
  2. Info.plist 能解析，且 CFBundleIdentifier / CFBundleExecutable 存在
  3. 可执行文件是 64 位小端 Mach-O，cputype = arm64，filetype = MH_EXECUTE
  4. 有 LC_BUILD_VERSION 且 platform = iOS（或老的 LC_VERSION_MIN_IPHONEOS）
  5. cryptid = 0（未加密，符合 App Store 之外的正常构建）
  6. 是否含 LC_CODE_SIGNATURE / _CodeSignature（判定能否直接自签）

用法：python scripts/verify_ipa.py dist/BPCNews-unsigned.ipa
退出码：0 = 全部通过；2 = 有硬性问题
"""
from __future__ import annotations

import plistlib
import struct
import sys
import zipfile
from pathlib import Path

LC_VERSION_MIN_IPHONEOS = 0x25
LC_ENCRYPTION_INFO_64 = 0x2C
LC_BUILD_VERSION = 0x32
LC_CODE_SIGNATURE = 0x1D

CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 0x2
PLATFORM_IOS = 2


def parse_macho(data: bytes) -> dict:
    magic = data[:4]
    if magic == b"\xcf\xfa\xed\xfe":
        endian, bits = "<", 64
    elif magic == b"\xce\xfa\xed\xfe":
        endian, bits = "<", 32
    elif magic == b"\xfe\xed\xfa\xcf":
        endian, bits = ">", 64
    else:
        return {"error": "不是 Mach-O（magic=%s）" % magic.hex()}

    if bits == 64:
        cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack(
            endian + "IIIIIII", data[4:32])
        off = 32
    else:
        cputype, cpusub, filetype, ncmds, sizeofcmds, flags = struct.unpack(
            endian + "IIIIII", data[4:28])
        off = 28

    info = {
        "bits": bits, "cputype": cputype, "cpusubtype": cpusub,
        "filetype": filetype, "ncmds": ncmds, "flags": flags,
        "platform": None, "minos": None, "sdk": None,
        "cryptid": None, "has_code_signature": False, "cmds": [],
    }

    for _ in range(ncmds):
        if off + 8 > len(data):
            break
        cmd, size = struct.unpack(endian + "II", data[off:off + 8])
        info["cmds"].append(cmd)
        if cmd == LC_BUILD_VERSION:
            plat, minos, sdk, _ntools = struct.unpack(endian + "IIII", data[off + 8:off + 24])
            info["platform"] = plat
            info["minos"] = "%d.%d.%d" % ((minos >> 16) & 0xFFFF, (minos >> 8) & 0xFF, minos & 0xFF)
            info["sdk"] = "%d.%d.%d" % ((sdk >> 16) & 0xFFFF, (sdk >> 8) & 0xFF, sdk & 0xFF)
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            minos, sdk = struct.unpack(endian + "II", data[off + 8:off + 16])
            info["platform"] = PLATFORM_IOS
            info["minos"] = "%d.%d" % ((minos >> 16) & 0xFFFF, (minos >> 8) & 0xFF)
            info["sdk"] = "%d.%d" % ((sdk >> 16) & 0xFFFF, (sdk >> 8) & 0xFF)
        elif cmd == LC_ENCRYPTION_INFO_64:
            _off, _size, cryptid = struct.unpack(endian + "III", data[off + 8:off + 20])
            info["cryptid"] = cryptid
        elif cmd == LC_CODE_SIGNATURE:
            info["has_code_signature"] = True
        off += size
    return info


def main(path: str) -> int:
    p = Path(path)
    if not p.exists():
        print("!! 文件不存在:", p)
        return 2

    print("IPA        :", p)
    print("大小        : %.2f MB" % (p.stat().st_size / 1024 / 1024))

    errs = []
    with zipfile.ZipFile(p) as z:
        names = z.namelist()
        print("条目数      :", len(names))

        app_dirs = sorted({n.split("/")[1] for n in names
                           if n.startswith("Payload/") and n.count("/") >= 2})
        if not app_dirs:
            errs.append("缺 Payload/*.app")
            print("\n".join(errs))
            return 2
        app = app_dirs[0]
        print("App         : Payload/%s" % app)

        plist_name = "Payload/%s/Info.plist" % app
        if plist_name not in names:
            errs.append("缺 Info.plist")
            pl = {}
        else:
            pl = plistlib.loads(z.read(plist_name))
            for k in ("CFBundleIdentifier", "CFBundleExecutable",
                      "CFBundleShortVersionString", "MinimumOSVersion"):
                print("  %-30s %s" % (k, pl.get(k, "<缺失>")))

        exe_name = pl.get("CFBundleExecutable") or app.replace(".app", "")
        exe_path = "Payload/%s/%s" % (app, exe_name)
        if exe_path not in names:
            errs.append("缺可执行文件 %s" % exe_path)
            macho = {}
        else:
            raw = z.read(exe_path)
            print("可执行文件  : %s (%.2f MB)" % (exe_path, len(raw) / 1024 / 1024))
            macho = parse_macho(raw)

        has_sig_files = any("_CodeSignature" in n for n in names)
        print("签名残留    :", "有 _CodeSignature" if has_sig_files else "无（干净，可自签）")

    # ---- Mach-O 判定 ----
    if macho:
        if "error" in macho:
            errs.append("Mach-O: " + macho["error"])
        else:
            arch = "arm64" if macho["cputype"] == CPU_TYPE_ARM64 else hex(macho["cputype"])
            ftype = "MH_EXECUTE" if macho["filetype"] == MH_EXECUTE else hex(macho["filetype"])
            plat = ("iOS" if macho["platform"] == PLATFORM_IOS
                    else ("未知(%s)" % macho["platform"]))
            print("架构        : %s (%d-bit)" % (arch, macho["bits"]))
            print("文件类型    :", ftype)
            print("平台        : %s  minos=%s  sdk=%s" % (plat, macho["minos"], macho["sdk"]))
            print("加密        : cryptid=%s %s"
                  % (macho["cryptid"], "（未加密）" if macho["cryptid"] == 0 else "（已加密）"))
            print("LC_CODE_SIGNATURE:",
                  "有" if macho["has_code_signature"] else "无（未签名，符合预期）")

            if macho["cputype"] != CPU_TYPE_ARM64:
                errs.append("不是 arm64 二进制")
            if macho["filetype"] != MH_EXECUTE:
                errs.append("不是可执行文件")
            if macho["platform"] != PLATFORM_IOS:
                errs.append("不是 iOS 平台")
            if macho["cryptid"] not in (None, 0):
                errs.append("二进制已加密（App Store 解密包才加密）")

    if pl and not pl.get("CFBundleIdentifier"):
        errs.append("Info.plist 缺 CFBundleIdentifier（签完装不上）")

    print()
    if errs:
        print("[FAIL]")
        for e in errs:
            print("  -", e)
        return 2
    print("[PASS] 这是一个真 arm64 iOS 未签名包，可以直接拿去自签")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "dist/BPCNews-unsigned.ipa"))
