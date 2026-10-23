#!/bin/bash
# 构建 TongMD.app（本地使用，ad-hoc 签名，不做公证）
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/TongMD.app"

# 这台机器只装了 Command Line Tools：把各种缓存重定向到工程内，
# 并关掉 SwiftPM 自带的 sandbox（嵌套 sandbox 会失败）。
mkdir -p .build/tmp .build/module-cache .build/spm-cache .build/spm-config
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
FLAGS=(--disable-sandbox --scratch-path .build --cache-path .build/spm-cache --config-path .build/spm-config)

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product TongMD "${FLAGS[@]}"

BIN="$(swift build -c "$CONFIG" --show-bin-path "${FLAGS[@]}")/TongMD"
if [ ! -x "$BIN" ]; then
    echo "构建产物不存在: $BIN" >&2
    exit 1
fi

echo "==> 组装 $APP"
if [ ! -f Resources/TongMD.icns ] || [ Resources/TongMD.icns -ot scripts/make-icon.swift ]; then
    ./scripts/make-icns.sh >/dev/null
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TongMD"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/TongMD.icns "$APP/Contents/Resources/TongMD.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ad-hoc 签名：本机运行足够，不需要开发者账号
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "==> 完成: $(pwd)/$APP"
echo "    启动: open '$APP'"
