#!/bin/bash
#
# Cross-compile the Swift shell for the ABIs in config.sh and stage it, with
# exactly the runtime libraries it needs, into the Gradle project's jniLibs.
#
# Needs Scripts/build-sdl.sh to have run first: the shell compiles against
# SDL's headers and links its .so, and Vendor/build.sh android, because the
# renderer links the text stack for the glyph atlas.
#
#   Scripts/build-shell.sh                  # both ABIs, release
#   Scripts/build-shell.sh --debug          # both ABIs, debug
#   Scripts/build-shell.sh arm64-v8a        # just one

. "$(dirname "$0")/config.sh"
require_ndk
use_swiftly

CONFIG=release
targets=()
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=release ;;
        --debug) CONFIG=debug ;;
        *) targets+=("$arg") ;;
    esac
done
[ ${#targets[@]} -eq 0 ] && targets=("${ABIS[@]}")

for abi in "${targets[@]}"; do
    triple="$(swift_triple "$abi")"
    prefix="$VENDOR_DIR/sdl3/$abi"
    if [ ! -d "$prefix/include" ]; then
        echo "no SDL for $abi — run Scripts/build-sdl.sh first" >&2
        exit 1
    fi

    # FreeType and HarfBuzz, found through pkg-config exactly as Android/Text
    # finds them. Without this the shell fails to resolve CTextShaping and
    # says so in a way that reads like a missing module rather than a missing
    # build step.
    text_prefix="$VENDOR_DIR/out/$(vendor_triple "$abi")"
    if [ ! -d "$text_prefix/lib/pkgconfig" ]; then
        echo "no FreeType/HarfBuzz for $abi — run Vendor/build.sh android first" >&2
        exit 1
    fi
    export PKG_CONFIG_PATH="$text_prefix/lib/pkgconfig"

    echo "==> building AndroidShell for $abi ($triple, $CONFIG)"
    # One array so the build and the --show-bin-path query cannot drift: a
    # mismatched flag there gives a path for a build that never happened.
    swiftpm=(
        --package-path "$ANDROID_DIR/Shell"
        --swift-sdk "$SWIFT_SDK"
        --triple "$triple"
        -c "$CONFIG"
        -Xcc "-I$prefix/include"
        -Xlinker "-L$prefix/lib"
        -Xlinker -lSDL3
        -Xlinker -lGLESv3
        -Xlinker -llog
    )
    swift build "${swiftpm[@]}"

    out="$(swift build "${swiftpm[@]}" --show-bin-path)/libAndroidShell.so"
    if [ ! -f "$out" ]; then
        echo "swift build produced no $out" >&2
        exit 1
    fi
    dest="$JNI_LIBS/$abi"
    rm -rf "$dest"
    mkdir -p "$dest"

    # The shell, then everything it and SDL need, found by walking DT_NEEDED.
    # That keeps the APK to the Swift runtime libraries actually referenced
    # rather than all 20-odd in the SDK bundle.
    stage_with_dependencies "$out" "$dest" "$abi"

    strip="$(ndk_tool llvm-strip)"
    [ -n "$strip" ] && "$strip" --strip-unneeded "$dest"/*.so 2>/dev/null || true

    echo "    staged $(ls "$dest"/*.so | wc -l | tr -d ' ') libraries, $(du -sh "$dest" | cut -f1) in $dest"
    ls "$dest" | sed 's/^/      /'
done
