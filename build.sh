#!/bin/bash
# 构建 代理启动器.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="代理启动器"
BUILD=build
APP="dist/${APP_NAME}.app"

rm -rf "$BUILD" dist
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码"
swiftc -O -swift-version 5 -parse-as-library \
    -o "$APP/Contents/MacOS/ProxyLauncher" \
    Sources/main.swift

echo "==> 生成图标"
swift make-icon.swift "$BUILD/icon-1024.png"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp Info.plist "$APP/Contents/Info.plist"

echo "==> 签名（本机 ad-hoc）"
codesign --force --deep -s - "$APP"

echo "==> 完成：$PWD/$APP"
