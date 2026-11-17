#!/bin/bash
#
# Cross-compile the Swift shell for the ABIs in config.sh and stage it, with
# exactly the runtime libraries it needs, into the Gradle project's jniLibs.
#
# Needs Scripts/build-sdl.sh to have run first: the shell compiles against
# SDL's headers and links its .so, and Vendor/build.sh android, because the
# renderer links the text stack for the glyph atlas.
#
#   Scripts/build-shell.sh --debug          # both ABIs, unoptimised: checks, emulator runs, pre-merge
#   Scripts/build-shell.sh                  # both ABIs, optimised, with DEBUG: frame-time measurements
#   Scripts/build-shell.sh --store          # optimised, without DEBUG: what goes to Play
#
# A --debug build's libraries are stripped as they're staged; an optimised
# build's keep their symbols, which `bundleRelease` puts in the bundle for
# Play and strips out of the APKs (README.md, "Native debug symbols").
#   Scripts/build-shell.sh --debug arm64-v8a  # just one ABI
#
# Build optimised only to measure frame times or to upload to Play; every
# other build, the last pass before a merge included, is `--debug`.
#
# The game's `#if DEBUG` is what lets it read its launch arguments
# (`LaunchArguments`), print markers and run its scripts, as an Xcode Debug
# build does. A debug build defines it, and so does an optimised one unless
# it's `--store`, so a frame-time run can still take `-StartLevel` and
# `-FrameLog`. What a release APK hands the game is MainActivity's to decide
# (it passes no arguments outside a debuggable build).

. "$(dirname "$0")/config.sh"
require_ndk
use_swiftly

CONFIG=release
DEBUG_DEFINE=1
targets=()
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=release ;;
        --debug) CONFIG=debug ;;
        --store) CONFIG=release; DEBUG_DEFINE=0 ;;
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

    echo "==> building AndroidShell for $abi ($triple, $CONFIG$([ "$DEBUG_DEFINE" = 1 ] && [ "$CONFIG" = release ] && echo ", DEBUG"))"
    # One array so the build and the --show-bin-path query cannot drift: a
    # mismatched flag there gives a path for a build that never happened.
    swiftpm=(
        --package-path "$ANDROID_DIR/Compat"
        --product AndroidShell
        --swift-sdk "$SWIFT_SDK"
        --triple "$triple"
        -c "$CONFIG"
        -Xcc "-I$prefix/include"
        -Xlinker "-L$prefix/lib"
    )
    # A debug build defines DEBUG itself; an optimised one that isn't for
    # the store is given it.
    if [ "$CONFIG" = release ] && [ "$DEBUG_DEFINE" = 1 ]; then
        swiftpm+=(-Xswiftc -DDEBUG)
    fi
    # An optimised build skips Swift's run-time exclusivity checks. On
    # Android each one reads thread-local storage through emulated TLS
    # (`__emutls_get_address`, `pthread_getspecific`), which came to about
    # a tenth of the game thread on a Galaxy M31. Debug builds keep them,
    # so a violation still traps where it's checked.
    if [ "$CONFIG" = release ]; then
        swiftpm+=(-Xswiftc -enforce-exclusivity=unchecked)
    fi
    # -lSDL3, -lGLESv3, -llog and -lmediandk used to be passed here. They cannot
    # be: `-Xlinker` reaches every link in the build, and since the shell
    # started linking GameCompat the build also makes a *host* macro plugin
    # (Macros, for @NSCodingUnsupported), whose macOS link then went looking
    # for libGLESv3. The libraries are named in Shell/Package.swift instead,
    # on the target that actually needs them. The search path above stays
    # here, because it is per ABI and harmless anywhere else.
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

    # A debug build is stripped here, so the APK every check and emulator run
    # installs stays small and quick to push. An optimised one is staged with
    # its symbols: the release variant's own strip (app/build.gradle.kts)
    # takes them out of the APKs and keeps them in the bundle's
    # BUNDLE-METADATA, so Play vitals shows readable native stacks.
    if [ "$CONFIG" = debug ]; then
        strip="$(ndk_tool llvm-strip)"
        [ -n "$strip" ] && "$strip" --strip-unneeded "$dest"/*.so 2>/dev/null || true
    fi

    echo "    staged $(ls "$dest"/*.so | wc -l | tr -d ' ') libraries, $(du -sh "$dest" | cut -f1) in $dest"
    ls "$dest" | sed 's/^/      /'
done
