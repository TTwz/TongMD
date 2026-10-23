#!/bin/bash
# 生成 Resources/TongMD.icns（从矢量绘制脚本烘成图标集）
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p .build/tmp .build/module-cache build/icon
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"

swift scripts/make-icon.swift build/icon/icon_1024.png

ICONSET=build/icon/TongMD.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for s in 16 32 128 256 512; do
    sips -z "$s" "$s" build/icon/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" build/icon/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/TongMD.icns
echo "==> Resources/TongMD.icns"
