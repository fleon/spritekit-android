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
# Builds SDL and FreeType/HarfBuzz for the ABI first if the checkout has none.

. "$(dirname "$0")/config.sh"
require_ndk
use_swiftly

abi="${1:-arm64-v8a}"
triple="$(swift_triple "$abi")"
sdl="$VENDOR_DIR/sdl3/$abi"
text="$VENDOR_DIR/out/$(vendor_triple "$abi")"
ensure_sdl "$abi" --unstaged
ensure_text "$abi"
export PKG_CONFIG_PATH="$text/lib/pkgconfig"

for package in "$RUNTIME_DIR" "$RUNTIME_DIR/Modules" "$RUNTIME_DIR/Shell" "$RUNTIME_DIR/Platform"; do
    echo "==> $(basename "$package") for $abi"
    swift build --package-path "$package" --swift-sdk "$SWIFT_SDK" --triple "$triple" \
        -Xcc "-I$sdl/include" -Xlinker "-L$sdl/lib"
done
echo "==> all four build for $abi"
