#!/bin/bash
# 微信多开助手 - 可选 DMG 打包脚本
# 用法: ./package_dmg.sh
# 需要先运行 ./build.sh；此脚本不签名、不公证，仅用于开源项目本地分发。
set -euo pipefail

cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "❌ 此脚本只能在 macOS 上运行。" >&2
    exit 1
fi

for command in hdiutil shasum; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "❌ 缺少命令：$command。" >&2
        exit 1
    fi
done

APP_NAME="微信多开助手"
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"
CHECKSUM="$DMG.sha256"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wechat-multi-opener-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

if [[ ! -d "$APP" ]]; then
    echo "❌ 找不到 $APP，请先运行 ./build.sh。" >&2
    exit 1
fi

rm -f "$DMG" "$CHECKSUM"
cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

/usr/bin/hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null
(
    cd "$DIST"
    /usr/bin/shasum -a 256 "$(basename "$DMG")" > "$(basename "$CHECKSUM")"
)

echo "✅ DMG 构建完成：$DMG"
echo "   SHA-256：$CHECKSUM"
