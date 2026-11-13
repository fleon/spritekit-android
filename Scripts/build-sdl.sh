#!/bin/bash
#
# Cross-compile SDL3 for the ABIs in config.sh and stage it for the APK.
#
# Fetches the pinned SDL tag (shallow) into Android/Vendor/SDL, builds a
# shared libSDL3.so per ABI, and copies SDL's own Java sources into the
# Gradle project. Nothing binary is checked in; this script is the source of
# truth for what ends up in the APK.
#
#   Scripts/build-sdl.sh            # both ABIs
#   Scripts/build-sdl.sh arm64-v8a  # just one

. "$(dirname "$0")/config.sh"
require_ndk

targets=("$@")
[ ${#targets[@]} -eq 0 ] && targets=("${ABIS[@]}")

mkdir -p "$VENDOR_DIR"

if [ ! -d "$SDL_SRC/.git" ]; then
    echo "==> fetching SDL $SDL_TAG"
    git clone --depth 1 --branch "$SDL_TAG" "$SDL_REPO" "$SDL_SRC"
else
    current="$(git -C "$SDL_SRC" describe --tags --exact-match 2>/dev/null || echo none)"
    if [ "$current" != "$SDL_TAG" ]; then
        echo "==> switching SDL to $SDL_TAG (was $current)"
        git -C "$SDL_SRC" fetch --depth 1 origin "refs/tags/$SDL_TAG:refs/tags/$SDL_TAG"
        git -C "$SDL_SRC" checkout -f "$SDL_TAG"
    fi
fi

for abi in "${targets[@]}"; do
    build="$VENDOR_DIR/build/sdl-$abi"
    prefix="$VENDOR_DIR/sdl3/$abi"
    echo "==> building SDL3 for $abi"
    cmake -S "$SDL_SRC" -B "$build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM="android-$ANDROID_API" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
    cmake --build "$build" --parallel
    cmake --install "$build" >/dev/null

    mkdir -p "$JNI_LIBS/$abi"
    cp "$prefix/lib/libSDL3.so" "$JNI_LIBS/$abi/"
    echo "    staged $JNI_LIBS/$abi/libSDL3.so"
done

# SDL's Android glue is Java: the activity, the GL surface, input, audio.
# It is part of SDL, not of this project, so it is copied rather than forked.
java_src="$SDL_SRC/android-project/app/src/main/java/org/libsdl/app"
java_dst="$ANDROID_DIR/App/app/src/main/java/org/libsdl/app"
rm -rf "$java_dst"
mkdir -p "$java_dst"
cp "$java_src"/*.java "$java_dst/"
echo "==> copied $(ls "$java_dst" | wc -l | tr -d ' ') SDL Java sources to App/app/src/main/java/org/libsdl/app"
