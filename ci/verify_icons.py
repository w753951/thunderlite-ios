#!/usr/bin/env python3
"""检查 ipa 里的 App 图标能不能被 iOS 正常渲染。

真正会让桌面只剩网格占位图的是这个：PNG 被 pngcrush 压成 CgBI 格式 ——
IHDR 前面多插一个 CgBI 块。这是 Xcode 的 COMPRESS_PNG_FILES 干的，
iOS 15 的 SpringBoard 解不开，于是画占位图。这条是硬失败。

alpha 通道只作提示，不算失败：App Store 上架的 App，bundle 里的图标 PNG
多数就是 RGBA（actool 从 Assets.car 反写出来的也是）。真正要求"不透明"
的是提交给 App Store 的那张 1024 母版，不是运行时 bundle 里的这些。

用法：python3 ci/verify_icons.py <path/to/ThunderLite.app>
"""
import os
import struct
import sys

SIG = b"\x89PNG\r\n\x1a\n"
TYPE_NAMES = {0: "Grayscale", 2: "RGB", 3: "Palette", 4: "Gray+Alpha", 6: "RGBA"}


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
    """返回 True 表示这张图没问题。CgBI 是硬失败。"""
    with open(path, "rb") as f:
        data = f.read()

    if data[:8] != SIG:
        print("::error title=icon::%s is not a PNG" % name)
        return False

    chunks = walk_chunks(data)
    kinds = [c[0] for c in chunks]

    if "CgBI" in kinds:
        print("::error title=icon::%s is CgBI-crushed; iOS cannot decode it "
              "(set COMPRESS_PNG_FILES=NO)" % name)
        return False

    ihdr = next((c for c in chunks if c[0] == "IHDR"), None)
    if ihdr is None:
        print("::error title=icon::%s has no IHDR" % name)
        return False

    _, off, _ = ihdr
    width, height = struct.unpack(">II", data[off:off + 8])
    colortype = data[off + 9]
    note = "  (has alpha, fine for runtime)" if colortype in (4, 6) else ""
    print("  ok %-28s %dx%-4d %s%s" % (
        name, width, height, TYPE_NAMES.get(colortype, str(colortype)), note))
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

