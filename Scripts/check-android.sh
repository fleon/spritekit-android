#!/bin/bash
#
# Cross-compiles the runtime's packages for Android on their own, with no
# game: the shim, renderer and platform layer, the module-name targets and
# the shell, and the platform code games share (Platform/). What every
# runtime change runs, beside `swift test` on the host.
#
#   Scripts/check-android.sh             # arm64-v8a
#   Scripts/check-android.sh x86_64
#
# Needs Vendor/build.sh android and Scripts/build-sdl.sh for the ABI first.

. "$(dirname "$0")/config.sh"
require_ndk
use_swiftly

abi="${1:-arm64-v8a}"
triple="$(swift_triple "$abi")"
sdl="$VENDOR_DIR/sdl3/$abi"
text="$VENDOR_DIR/out/$(vendor_triple "$abi")"
[ -d "$sdl/include" ] || { echo "no SDL for $abi — run Scripts/build-sdl.sh $abi first" >&2; exit 1; }
[ -d "$text/lib/pkgconfig" ] || { echo "no FreeType/HarfBuzz for $abi — run Vendor/build.sh android first" >&2; exit 1; }
export PKG_CONFIG_PATH="$text/lib/pkgconfig"

for package in "$RUNTIME_DIR" "$RUNTIME_DIR/Modules" "$RUNTIME_DIR/Shell" "$RUNTIME_DIR/Platform"; do
    echo "==> $(basename "$package") for $abi"
    swift build --package-path "$package" --swift-sdk "$SWIFT_SDK" --triple "$triple" \
        -Xcc "-I$sdl/include" -Xlinker "-L$sdl/lib"
done
echo "==> all four build for $abi"
