#!/bin/bash
# 检测并准备一份可用的 Swift 工具链，输出 shell 变量供 eval 使用：
#
#   eval "$(tools/prepare-toolchain.sh)"
#
# 得到 SWIFTC（编译器）、SWIFT（脚本解释器）、SDK（SDK 路径）。
#
# ── 为什么需要这个脚本 ──────────────────────────────────────────────
#
# 只装了 Command Line Tools（没装完整 Xcode）时，CLT 附带的 macOS SDK 里只有
# .swiftinterface 文本接口（没有二进制 .swiftmodule），而这些接口是用更早版本的
# swiftc 生成的。本机编译器会直接拒绝使用它们：
#
#   error: failed to build module 'Foundation'; this SDK is not supported by the
#   compiler (the SDK is built with 'swiftlang-6.0.3.1.5', while this compiler is
#   'swiftlang-6.0.3.1.10')
#
# 同时 CLT 多次升级后，usr/include/swift/ 下会残留旧版的 module.modulemap，与
# bridging.modulemap 冲突：
#
#   error: redefinition of module 'SwiftBridging'
#
# 这两个问题都属于本机工具链状态，build.sh 本身无法修复。完整安装 Xcode 后
# SDK 会带上二进制 .swiftmodule，就不会出现上面的报错。
#
# ── 这里的做法 ──────────────────────────────────────────────────────
#
# 编译前先用一段最小代码探测系统工具链；探测失败就在缓存目录里搭一份
# "影子工具链"：把 swift-frontend 硬链接过去、工具链资源目录软链接回原处。
# 编译器是从自身路径推算工具链根目录的，影子目录下没有那份残留的
# module.modulemap，于是冲突消失，SDK 的接口也能正常编译。
#
# 整个过程不改动系统文件，也不需要管理员权限。
#
# 环境变量：
#   PROXYLAUNCHER_TOOLCHAIN_CACHE   影子工具链的缓存目录
#   PROXYLAUNCHER_FORCE_REAL_TOOLCHAIN=1  强制使用系统工具链（不做影子）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${MACOSX_DEPLOYMENT_TARGET:-arm64-apple-macos13}"
CACHE="${PROXYLAUNCHER_TOOLCHAIN_CACHE:-$HOME/Library/Caches/proxylauncher-toolchain}"
SHADOW="$CACHE/toolchain"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
REAL_SWIFTC="$(xcrun --find swiftc)"
REAL_BIN="$(cd "$(dirname "$REAL_SWIFTC")" && pwd)"
REAL_ROOT="$(cd "$REAL_BIN/../.." && pwd)"

# 用一小段需要 Foundation 的代码探测工具链是否可用
probe() {
    local swiftc="$1" dir rc
    dir="$(mktemp -d)"
    printf 'import Foundation\nlet _ = URL(fileURLWithPath: "/")\n' > "$dir/probe.swift"
    "$swiftc" -typecheck -swift-version 5 -target "$TARGET" -sdk "$SDK" "$dir/probe.swift" >/dev/null 2>&1
    rc=$?
    rm -rf "$dir"
    return $rc
}

# 搭建影子工具链
build_shadow() {
    local shadow="$1" name
    mkdir -p "$shadow/usr/bin" "$shadow/usr/lib"

    # swift-frontend 必须是硬链接或真实副本：用软链接会被解析回系统目录，
    # 那样残留的 module.modulemap 又会被加载进来。
    if ! ln -f "$REAL_BIN/swift-frontend" "$shadow/usr/bin/swift-frontend" 2>/dev/null; then
        cp "$REAL_BIN/swift-frontend" "$shadow/usr/bin/swift-frontend"
    fi

    for name in swiftc swift swift-api-digester swift-api-extract swift-cache-tool; do
        ln -sf swift-frontend "$shadow/usr/bin/$name"
    done
    for name in swift-driver swift-driver-new; do
        if [ -e "$REAL_BIN/$name" ]; then
            ln -sf "$REAL_BIN/$name" "$shadow/usr/bin/$name"
        fi
    done
    for f in "$REAL_BIN"/*; do
        name="$(basename "$f")"
        [ -e "$shadow/usr/bin/$name" ] || ln -sf "$f" "$shadow/usr/bin/$name"
    done

    # 资源目录指回系统原处（不复制，省磁盘）；include 目录故意不建，
    # 这样编译器推算出的工具链根目录里就没有那份残留的 module.modulemap。
    ln -sfn "$REAL_ROOT/usr/lib/swift" "$shadow/usr/lib/swift"
}

emit() {
    printf "SWIFTC='%s'\n" "$1"
    printf "SWIFT='%s'\n" "$2"
    printf "SDK='%s'\n" "$3"
}

if [ "${PROXYLAUNCHER_FORCE_REAL_TOOLCHAIN:-0}" = "1" ]; then
    echo "prepare-toolchain: 强制使用系统工具链 $REAL_SWIFTC" >&2
    emit "$REAL_SWIFTC" "$REAL_BIN/swift" "$SDK"
    exit 0
fi

if probe "$REAL_SWIFTC"; then
    emit "$REAL_SWIFTC" "$REAL_BIN/swift" "$SDK"
    exit 0
fi

echo "prepare-toolchain: 系统工具链与 SDK 不匹配，启用影子工具链" >&2
echo "prepare-toolchain: （彻底解决请安装完整 Xcode）" >&2

if [ ! -x "$SHADOW/usr/bin/swiftc" ]; then
    build_shadow "$SHADOW"
fi

if ! probe "$SHADOW/usr/bin/swiftc"; then
    echo "prepare-toolchain: 影子工具链仍然不可用，请安装完整 Xcode：" >&2
    echo "  https://developer.apple.com/xcode/downloads/" >&2
    exit 1
fi

emit "$SHADOW/usr/bin/swiftc" "$SHADOW/usr/bin/swift" "$SDK"
