# shellcheck shell=bash
# Shared settings for the Android shell's build scripts.
#
# Everything the scripts need to agree on lives here: the pinned SDL version,
# the ABIs we ship, and where fetched and built things land.

set -euo pipefail

# SDL3, pinned. Bump this tag and rerun Scripts/build-sdl.sh to move.
SDL_TAG="release-3.4.20"
SDL_REPO="https://github.com/libsdl-org/SDL"

# The ABIs the APK ships: phones and Apple Silicon emulators (arm64-v8a),
# and Intel emulator images (x86_64).
ABIS=("arm64-v8a" "x86_64")

# The Android API level the native code is *compiled against*. The NDK links
# it against this level's stubs, so the .so uses no symbol newer than it.
# Kept at 23 because that is the level the runtime has been proved on. An
# app's own minSdk may be higher (its Gradle project's); that is allowed and
# deliberate — a binary may require less than the app declares.
ANDROID_API=23

# The runtime's own checkout: its vendored builds (SDL, FreeType, HarfBuzz)
# live under it, gitignored.
RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$RUNTIME_DIR/Vendor"

# The game being built. The runtime is checked out as a submodule named
# spritekit-android inside the game's Android directory, so that directory
# is the runtime's parent unless GAME_ANDROID_DIR says otherwise. The game's
# package (the one with the AndroidShell product: its sources, its entry and
# the shell) and its Gradle project default to Game/ and App/ there.
GAME_ANDROID_DIR="${GAME_ANDROID_DIR:-$(cd "$RUNTIME_DIR/.." && pwd)}"
GAME_PACKAGE_DIR="${GAME_PACKAGE_DIR:-$GAME_ANDROID_DIR/Game}"
APP_DIR="${APP_DIR:-$GAME_ANDROID_DIR/App}"
SDL_SRC="$VENDOR_DIR/SDL"
JNI_LIBS="$APP_DIR/app/src/main/jniLibs"

# What Vendor/build.sh calls an ABI's prefix, e.g. arm64-v8a ->
# aarch64-linux-android. Not the Swift triple: that carries the API level.
vendor_triple() {
    case "$1" in
        arm64-v8a) echo "aarch64-linux-android" ;;
        x86_64)    echo "x86_64-linux-android" ;;
        *) echo "unknown ABI: $1" >&2; return 1 ;;
    esac
}

# The Swift triple for an ABI, e.g. arm64-v8a -> aarch64-unknown-linux-android23
swift_triple() {
    case "$1" in
        arm64-v8a) echo "aarch64-unknown-linux-android$ANDROID_API" ;;
        x86_64)    echo "x86_64-unknown-linux-android$ANDROID_API" ;;
        *) echo "unknown ABI: $1" >&2; return 1 ;;
    esac
}

# SDL and the text stack (FreeType, HarfBuzz) for an ABI, built the first
# time a checkout needs them: both live in the gitignored Vendor/, so every
# fresh clone and worktree starts without them. The builds' output goes to
# stderr, so a script's stdout stays its own.
# For a game's build, SDL also counts as missing when it isn't staged into
# the game's jniLibs (a cleaned App), which build-sdl.sh redoes
# incrementally; `--unstaged` (the runtime's own checks, with no game) asks
# for the build alone and stages nothing, so a standalone clone never grows
# an App beside it.
ensure_sdl() { # abi [--unstaged]
    local abi="$1" unstaged=0
    [ "${2:-}" = --unstaged ] && unstaged=1
    if [ -d "$VENDOR_DIR/sdl3/$abi/include" ]; then
        [ "$unstaged" = 1 ] || [ -f "$JNI_LIBS/$abi/libSDL3.so" ] && return 0
    fi
    echo "==> no SDL for $abi in this checkout or the game: building it (Scripts/build-sdl.sh $abi)" >&2
    if [ "$unstaged" = 1 ]; then
        "$RUNTIME_DIR/Scripts/build-sdl.sh" --no-stage "$abi" >&2
    else
        "$RUNTIME_DIR/Scripts/build-sdl.sh" "$abi" >&2
    fi
    [ -d "$VENDOR_DIR/sdl3/$abi/include" ] || { echo "building SDL for $abi failed: see its output above" >&2; exit 1; }
}

ensure_text() { # abi
    local abi="$1" prefix
    prefix="$VENDOR_DIR/out/$(vendor_triple "$abi")"
    [ -d "$prefix/lib/pkgconfig" ] && return 0
    echo "==> no FreeType/HarfBuzz for $abi in this checkout: building them (Vendor/build.sh $abi)" >&2
    "$VENDOR_DIR/build.sh" "$abi" >&2
    [ -d "$prefix/lib/pkgconfig" ] || { echo "building FreeType/HarfBuzz for $abi failed: see its output above" >&2; exit 1; }
}

require_ndk() {
    : "${ANDROID_NDK_HOME:=$HOME/Library/Android/android-ndk-r30}"
    if [ ! -d "$ANDROID_NDK_HOME" ]; then
        echo "ANDROID_NDK_HOME is not a directory: $ANDROID_NDK_HOME" >&2
        exit 1
    fi
    export ANDROID_NDK_HOME
}

# swiftly's toolchain, not Xcode's: Xcode's Swift cannot cross-compile.
use_swiftly() {
    if [ -f "$HOME/.swiftly/env.sh" ]; then
        # shellcheck disable=SC1091
        . "$HOME/.swiftly/env.sh"
    fi
}

SWIFT_SDK="swift-6.4.2-RELEASE_android"
# SwiftPM keeps installed SDKs in ~/.swiftpm on a Mac and under the XDG config
# folder on Linux.
SWIFT_SDK_BUNDLE="$HOME/.swiftpm/swift-sdks/$SWIFT_SDK.artifactbundle"
for sdks in "$HOME/.swiftpm/swift-sdks" "${XDG_CONFIG_HOME:-$HOME/.config}/swiftpm/swift-sdks"; do
    if [ -d "$sdks/$SWIFT_SDK.artifactbundle" ]; then
        SWIFT_SDK_BUNDLE="$sdks/$SWIFT_SDK.artifactbundle"
        break
    fi
done

# Where the Swift runtime .so files for an ABI live inside the SDK bundle.
swift_sdk_lib_dir() {
    case "$1" in
        arm64-v8a) echo "$SWIFT_SDK_BUNDLE/swift-android/swift-resources/usr/lib/swift-aarch64/android" ;;
        x86_64)    echo "$SWIFT_SDK_BUNDLE/swift-android/swift-resources/usr/lib/swift-x86_64/android" ;;
        *) return 1 ;;
    esac
}

# The NDK's own shared libraries for an ABI — libc++_shared.so lives here.
ndk_lib_dir() {
    local triple
    case "$1" in
        arm64-v8a) triple="aarch64-linux-android" ;;
        x86_64)    triple="x86_64-linux-android" ;;
        *) return 1 ;;
    esac
    # darwin-x86_64 on a Mac, linux-x86_64 on Linux: an NDK ships one.
    local prebuilt
    prebuilt="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 -type d | head -1)"
    echo "$prebuilt/sysroot/usr/lib/$triple"
}

# The NDK ships llvm-readelf and llvm-strip as symlinks, so this must not
# filter on -type f.
ndk_tool() {
    find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -name "$1" \( -type f -o -type l \) | head -1
}

# Libraries Android itself provides. Shipping copies of these in the APK is
# wrong: the device's own must be used.
SYSTEM_LIBS="libc.so libm.so libdl.so liblog.so libandroid.so libz.so \
libGLESv1_CM.so libGLESv2.so libGLESv3.so libEGL.so libOpenSLES.so \
libjnigraphics.so libvulkan.so libaaudio.so libcamera2ndk.so libmediandk.so \
libnativewindow.so libstdc++.so ld-android.so libneuralnetworks.so"

# Copy a library into $2 along with every shared library it needs (and every
# library those need), skipping the ones Android provides. Searches the SDL
# prefix, the Swift SDK and the NDK, in that order.
stage_with_dependencies() {
    local lib="$1" dest="$2" abi="$3"
    local name; name="$(basename "$lib")"
    case " $SYSTEM_LIBS " in *" $name "*) return 0 ;; esac
    [ -f "$dest/$name" ] && return 0
    [ -f "$lib" ] || return 0

    cp "$lib" "$dest/"
    local readelf; readelf="$(ndk_tool llvm-readelf)"
    [ -n "$readelf" ] || return 0

    local needed
    needed="$("$readelf" -d "$lib" 2>/dev/null | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p')"
    local search=("$VENDOR_DIR/sdl3/$abi/lib" "$(swift_sdk_lib_dir "$abi")" "$(ndk_lib_dir "$abi")")
    local dep dir
    for dep in $needed; do
        case " $SYSTEM_LIBS " in *" $dep "*) continue ;; esac
        [ -f "$dest/$dep" ] && continue
        for dir in "${search[@]}"; do
            if [ -f "$dir/$dep" ]; then
                stage_with_dependencies "$dir/$dep" "$dest" "$abi"
                break
            fi
        done
    done
}
