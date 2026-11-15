#!/usr/bin/env python3
"""检查 ipa 里的 App 图标能不能被 iOS 正常渲染。

踩过的两个坑，都会让桌面只剩网格占位图：

  1. PNG 带 alpha 通道（colortype 4/6，或调色板类型 3）。App 图标必须不透明，
     iOS 会直接拒绝渲染。
  2. PNG 被 pngcrush 压成 CgBI 格式 —— IHDR 前面多插一个 CgBI 块。这是
     Xcode 的 COMPRESS_PNG_FILES 干的，iOS 15 的 SpringBoard 解不开。

用法：python3 ci/verify_icons.py <path/to/ThunderLite.app>
"""
import os
import struct
import sys

SIG = b"\x89PNG\r\n\x1a\n"
OPAQUE_TYPES = {0: "Grayscale", 2: "RGB"}


def walk_chunks(data):
    """返回 [(chunk_type, data_offset, length)]，遇到 IEND 停。"""
    out = []
    pos = 8
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        ctype = data[pos + 4:pos + 8].decode("latin1", "replace")
        out.append((ctype, pos + 8, length))
        if ctype == "IEND":
            break
        pos += 12 + length
    return out


def check(path, name):
    with open(path, "rb") as f:
        data = f.read()

    if data[:8] != SIG:
        print("::error title=icon::%s is not a PNG" % name)
        return False

    chunks = walk_chunks(data)
    kinds = [c[0] for c in chunks]

    if "CgBI" in kinds:
        print("::error title=icon::%s is CgBI-crushed; "
              "iOS cannot decode it (set COMPRESS_PNG_FILES=NO)" % name)
        return False

    ihdr = next((c for c in chunks if c[0] == "IHDR"), None)
    if ihdr is None:
        print("::error title=icon::%s has no IHDR" % name)
        return False

    _, off, _ = ihdr
    width, height = struct.unpack(">II", data[off:off + 8])
    colortype = data[off + 9]

    if colortype in (3, 4, 6):
        print("::error title=icon::%s has an alpha channel (colortype=%d); "
              "app icons must be opaque" % (name, colortype))
        return False

    print("  ok %-28s %dx%-4d colortype=%d (%s)" % (
        name, width, height, colortype, OPAQUE_TYPES[colortype]))
    return True


def main():
    if len(sys.argv) != 2:
        print("usage: verify_icons.py <ThunderLite.app>")
        return 2

    app = sys.argv[1]
    if not os.path.isdir(app):
        print("::error title=icon::%s is not a directory" % app)
        return 1

    names = sorted(n for n in os.listdir(app)
                   if n.startswith("AppIcon") and n.endswith(".png"))
    if not names:
        print("::error title=icon::no AppIcon*.png in the bundle")
        return 1

    # iPhone 上真正会用到的两档，必须存在。
    for required in ("AppIcon60x60@2x.png", "AppIcon60x60@3x.png"):
        if required not in names:
            print("::error title=icon::%s missing" % required)
            return 1

    ok = all([check(os.path.join(app, n), n) for n in names])

    car = os.path.join(app, "Assets.car")
    if not os.path.exists(car):
        print("::error title=icon::Assets.car missing")
        ok = False
    else:
        print("  ok Assets.car %d bytes" % os.path.getsize(car))

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
