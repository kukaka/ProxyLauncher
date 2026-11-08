#!/bin/bash
# 构建 代理启动器.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ProxyLauncher"
BUILD=build
APP="dist/${APP_NAME}.app"
TARGET="arm64-apple-macos13"

# 准备可用的编译器与 SDK（部分机器只装了 Command Line Tools，SDK 与编译器版本
# 不匹配会报 "this SDK is not supported by the compiler"，详见脚本内注释）
TOOLCHAIN_ENV="$(tools/prepare-toolchain.sh)"
eval "$TOOLCHAIN_ENV"

# 构建号：每次构建自增，并写进 app 的 Info.plist，界面上会显示出来，
# 这样一眼就能确认「我现在跑的是哪一版构建」。
BUILD_NUMBER_FILE="BUILD_NUMBER"
LAST=0
if [ -f "$BUILD_NUMBER_FILE" ]; then
    LAST="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
fi
case "$LAST" in (''|*[!0-9]*) LAST=0 ;; esac
BUILD_NUMBER=$((LAST + 1))
echo "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"
BUILD_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
echo "==> 构建号 #${BUILD_NUMBER}（${BUILD_TIME}）"

rm -rf "$BUILD" dist
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码（Apple Silicon：arm64）"
"$SWIFTC" -O -swift-version 5 -parse-as-library \
    -target "$TARGET" -sdk "$SDK" \
    -o "$APP/Contents/MacOS/ProxyLauncher" \
    Sources/main.swift \
    Sources/DouyinHighQuality.swift

echo "==> 编译独立启动器组件（原生可执行文件）"
"$SWIFTC" -O -swift-version 5 -parse-as-library \
    -target "$TARGET" -sdk "$SDK" \
    -o "$APP/Contents/Resources/launcher-stub" \
    Sources/LauncherStub.swift

echo "==> 复制抖音画质补丁"
cp Sources/douyin-hq-preload.js "$APP/Contents/Resources/"

echo "==> 生成图标"
"$SWIFT" -sdk "$SDK" make-icon.swift "$BUILD/icon-1024.png"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp Info.plist "$APP/Contents/Info.plist"
# 把构建号和构建时间写进 Info.plist，界面底部会显示
/usr/libexec/PlistBuddy -c "Set :PLBuildNumber $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :PLBuildTime $BUILD_TIME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1.3.$BUILD_NUMBER" "$APP/Contents/Info.plist"

echo "==> 签名（本机 ad-hoc）"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ARCHIVE="dist/ProxyLauncher-${VERSION}-build${BUILD_NUMBER}-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

echo "==> 完成：$PWD/$APP"
echo "==> 安装包：$PWD/$ARCHIVE"
