#!/usr/bin/env bash
#
# Runs the game's own text layout on an attached Android device or emulator.
#
#   ./run-probe.sh
#
# GameProbe calls `wrappedLines`, `UIFont.capitalsOffset` and `TextBlockNode`
# straight out of Source/Utils/TextHelpers.swift. A build proves that file
# compiles on Android; this proves it works there, which is a different
# question — on Android its NSAttributedString is corelibs Foundation's
# holding a Swift class, and its CTTypesetter is the shim's reading that
# back. Neither can be checked by compiling, and neither can be checked on a
# Mac, where the real CoreText is used instead.
#
# Needs: an emulator or device on adb, the Swift SDK, the NDK, and
# ../Vendor built for the device's ABI.
set -euo pipefail

# Xcode's Swift cannot cross-compile, and it is what a plain `swift` on the
# PATH usually is.
# shellcheck disable=SC1091
[ -f "$HOME/.swiftly/env.sh" ] && . "$HOME/.swiftly/env.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDK="${ANDROID_NDK_HOME:-$HOME/Library/Android/android-ndk-r30}"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
DEVICE_DIR=/data/local/tmp/switchlings-text

abi="$("$ADB" shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$abi" in
    arm64-v8a) arch=aarch64 ;;
    x86_64)    arch=x86_64 ;;
    *) echo "error: unsupported ABI $abi (arm64-v8a and x86_64 only)" >&2; exit 1 ;;
esac
echo "device is $abi"

VENDOR="$HERE/../Vendor/out/$arch-linux-android/lib/pkgconfig"
[ -d "$VENDOR" ] || { echo "error: run ../Vendor/build.sh android first" >&2; exit 1; }

echo "building"
PKG_CONFIG_PATH="$VENDOR" swift build \
    --swift-sdk swift-6.4.2-RELEASE_android \
    --triple "$arch-unknown-linux-android23" \
    --product GameProbe

RUNTIME="$HOME/.swiftpm/swift-sdks/swift-6.4.2-RELEASE_android.artifactbundle/swift-android/swift-resources/usr/lib/swift-$arch/android"
LIBCXX="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/$arch-linux-android/libc++_shared.so"

echo "pushing"
"$ADB" shell rm -rf "$DEVICE_DIR"
"$ADB" shell mkdir -p "$DEVICE_DIR/fonts"
"$ADB" push "$RUNTIME"/*.so "$DEVICE_DIR/" > /dev/null
# The Swift runtime wants this; the text stack itself does not — FreeType and
# HarfBuzz come in as static archives carrying the NDK's own libc++.
"$ADB" push "$LIBCXX" "$DEVICE_DIR/" > /dev/null
"$ADB" push "$HERE/.build/out/Products/Debug-android-$arch/GameProbe" "$DEVICE_DIR/" > /dev/null
"$ADB" push "$REPO/Assets/Fonts/"*.ttf "$DEVICE_DIR/fonts/" > /dev/null
"$ADB" shell chmod +x "$DEVICE_DIR/GameProbe"

echo "running"
"$ADB" shell "cd $DEVICE_DIR && LD_LIBRARY_PATH=$DEVICE_DIR ./GameProbe $DEVICE_DIR/fonts"
