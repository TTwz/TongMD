#!/bin/bash
# 打包可安装的 DMG：TongMD.app + 拖进 Applications 的快捷方式
#
# 注意：hdiutil / diskutil 需要创建并挂载磁盘映像，普通文件沙盒下会被拒绝，
# 需要在登录用户自己的终端里运行（或给足权限）。
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
DMG="build/TongMD-${VERSION}.dmg"
STAGE="build/dmg-stage"
MOUNT="build/dmg-mount"

./scripts/build-app.sh release

echo "==> 准备磁盘映像内容"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto build/TongMD.app "$STAGE/TongMD.app"
ln -s /Applications "$STAGE/Applications"

echo "==> 生成 $DMG"
rm -f "$DMG"
# 优先用新接口；失败再退回 hdiutil（新系统会给 deprecation 警告，但仍可用）
if ! diskutil image create from --format UDZO --volumeName "TongMD" "$STAGE" "$DMG" >/dev/null 2>&1; then
    rm -f "$DMG"
    hdiutil create -volname "TongMD" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
fi
rm -rf "$STAGE"

echo "==> 冒烟检查（挂载 → 校验 → 卸载）"
rm -rf "$MOUNT"
mkdir -p "$MOUNT"
cleanup() {
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null

test -d "$MOUNT/TongMD.app" || { echo "DMG 里没有 TongMD.app" >&2; exit 1; }
test -L "$MOUNT/Applications" || { echo "DMG 里缺少 Applications 链接" >&2; exit 1; }
test -f "$MOUNT/TongMD.app/Contents/Resources/TongMD.icns" || { echo "图标没打进去" >&2; exit 1; }
codesign --verify --deep --strict "$MOUNT/TongMD.app"

SIZE="$(du -h "$DMG" | cut -f1)"
echo "==> 完成: $DMG ($SIZE)"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
