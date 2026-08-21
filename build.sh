#!/bin/bash
# 微信多开助手 - 一键构建脚本
# 用法: ./build.sh
# 产物: dist/微信多开助手.app、dist/微信多开助手.zip、dist/微信多开助手.zip.sha256
set -euo pipefail

cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "❌ 此脚本只能在 macOS 上运行。" >&2
    exit 1
fi

for command in xcrun lipo codesign ditto plutil shasum; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "❌ 缺少命令：$command。请确认已安装 Xcode Command Line Tools。" >&2
        exit 1
    fi
done

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "❌ 找不到 Swift 编译器。请安装 Xcode Command Line Tools 后重试。" >&2
    exit 1
fi

APP_NAME="微信多开助手"
EXEC_NAME="WeChatMultiOpener"
DIST="dist"
APP="$DIST/$APP_NAME.app"
ZIP="$DIST/$APP_NAME.zip"
CHECKSUM="$ZIP.sha256"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wechat-multi-opener-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

rm -rf "$APP"
rm -f "$ZIP" "$CHECKSUM"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/Info.plist"

echo "[1/3] 编译 Swift 源码..."
xcrun swiftc -swift-version 5 -O -parse-as-library \
    -target arm64-apple-macos13.0 \
    -o "$BUILD_DIR/$EXEC_NAME-arm64" \
    main.swift
xcrun swiftc -swift-version 5 -O -parse-as-library \
    -target x86_64-apple-macos13.0 \
    -o "$BUILD_DIR/$EXEC_NAME-x86_64" \
    main.swift
/usr/bin/lipo -create \
    "$BUILD_DIR/$EXEC_NAME-arm64" \
    "$BUILD_DIR/$EXEC_NAME-x86_64" \
    -output "$APP/Contents/MacOS/$EXEC_NAME"

# 若存在图标则复制
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "[2/3] ad-hoc 签名..."
/usr/bin/codesign --force --deep --sign - "$APP"

echo "[3/3] 校验并打 zip（方便分发）..."
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP"

ARCHS="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/$EXEC_NAME")"
if [[ "$ARCHS" != *arm64* || "$ARCHS" != *x86_64* ]]; then
    echo "❌ 产物不是 Universal arm64 + x86_64：$ARCHS" >&2
    exit 1
fi

if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" != "com.lei.wechat-multi-opener" ]]; then
    echo "❌ App Bundle ID 校验失败。" >&2
    exit 1
fi

/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
(
    cd "$DIST"
    /usr/bin/shasum -a 256 "$(basename "$ZIP")" > "$(basename "$CHECKSUM")"
)

echo "✅ 构建完成：$APP"
echo "   Universal 架构：$ARCHS"
echo "   分发压缩包：$ZIP"
echo "   SHA-256：$CHECKSUM"
