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
# Kept at 23 because that is the level the merged shim work (PR #384) proved.
# The app's own minSdk is higher (see Android/App/gradle.properties); that is
# allowed and deliberate — a binary may require less than the app declares.
ANDROID_API=23

ANDROID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ANDROID_DIR/Vendor"
SDL_SRC="$VENDOR_DIR/SDL"
JNI_LIBS="$ANDROID_DIR/App/app/src/main/jniLibs"

# The Swift triple for an ABI, e.g. arm64-v8a -> aarch64-unknown-linux-android23
swift_triple() {
    case "$1" in
        arm64-v8a) echo "aarch64-unknown-linux-android$ANDROID_API" ;;
        x86_64)    echo "x86_64-unknown-linux-android$ANDROID_API" ;;
        *) echo "unknown ABI: $1" >&2; return 1 ;;
    esac
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
SWIFT_SDK_BUNDLE="$HOME/.swiftpm/swift-sdks/$SWIFT_SDK.artifactbundle"

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
    echo "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/$triple"
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
