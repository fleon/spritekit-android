#!/usr/bin/env bash
#
# Builds FreeType and HarfBuzz for the host and for both Android ABIs.
#
#   ./build.sh              everything (host, arm64-v8a, x86_64)
#   ./build.sh host         just the Mac, which is what `swift test` needs
#   ./build.sh android      just the two device ABIs
#
# Nothing binary is committed: this fetches the pinned tarballs in
# versions.sh, checks their hashes and builds static libraries into
# out/<target>/. Both out/ and src/ are gitignored.
#
# FreeType is built first and without HarfBuzz (its optional HarfBuzz
# dependency only improves autohinting and would make the two circular),
# then HarfBuzz is built against it so hb-ft.h can share one FT_Face
# between shaping and rasterising — the metrics then agree by construction.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/versions.sh"

SRC="$HERE/src"
OUT="$HERE/out"
mkdir -p "$SRC" "$OUT"

NDK="${ANDROID_NDK_HOME:-$HOME/Library/Android/android-ndk-r30}"

fetch() { # url sha256 file
    local url="$1" want="$2" file="$SRC/$3"
    if [ -f "$file" ]; then
        local have
        have="$(shasum -a 256 "$file" | cut -d' ' -f1)"
        [ "$have" = "$want" ] && return 0
        echo "  $3 hash mismatch, refetching" >&2
        rm -f "$file"
    fi
    echo "  fetching $3"
    curl -fsSL -o "$file" "$url"
    local have
    have="$(shasum -a 256 "$file" | cut -d' ' -f1)"
    if [ "$have" != "$want" ]; then
        echo "error: $3 sha256 $have, expected $want" >&2
        rm -f "$file"
        exit 1
    fi
}

unpack() { # tarball dirname
    local dir="$SRC/$2"
    [ -d "$dir" ] && return 0
    echo "  unpacking $2"
    tar -xf "$SRC/$1" -C "$SRC"
}

# FreeType with every optional codec off: the game ships plain TrueType, and
# each of these would be another thing to cross-compile. Variable-font
# support (Chiron GoRound TC is variable) needs none of them.
FT_FLAGS=(
    -DFT_DISABLE_ZLIB=ON
    -DFT_DISABLE_BZIP2=ON
    -DFT_DISABLE_PNG=ON
    -DFT_DISABLE_BROTLI=ON
    -DFT_DISABLE_HARFBUZZ=ON
    # FreeType 2.15 picks up Apple's HVF library when it finds the SDK, and
    # then needs -lhvf to link. Android has no such thing, so it is off
    # everywhere and the host build stays the same build the device gets.
    -DFT_DISABLE_HVF=ON
)

# HarfBuzz with FreeType, and nothing else. CoreText is forced off so the Mac
# build takes exactly the code path Android does — otherwise a host test could
# pass through a shaper the device never runs.
HB_FLAGS=(
    -DHB_HAVE_FREETYPE=ON
    -DHB_HAVE_CORETEXT=OFF
    -DHB_HAVE_GLIB=OFF
    -DHB_HAVE_ICU=OFF
    -DHB_HAVE_GOBJECT=OFF
    -DHB_HAVE_GRAPHITE2=OFF
    -DHB_BUILD_SUBSET=OFF
    -DHB_BUILD_UTILS=OFF
    -DHB_BUILD_TESTS=OFF
)

write_pc() { # prefix
    local prefix="$1"
    mkdir -p "$prefix/lib/pkgconfig"
    # One .pc for the single system-library target, so SwiftPM never has to
    # resolve a Requires: chain. Only -I, -L and -l, which is all SwiftPM's
    # pkg-config allowlist accepts.
    cat > "$prefix/lib/pkgconfig/switchlings-text.pc" <<EOF
prefix=$prefix
Name: switchlings-text
Description: FreeType $FREETYPE_VERSION and HarfBuzz $HARFBUZZ_VERSION, pinned by Android/Vendor
Version: ${FREETYPE_VERSION}+${HARFBUZZ_VERSION}
Cflags: -I\${prefix}/include -I\${prefix}/include/freetype2 -I\${prefix}/include/harfbuzz
Libs: -L\${prefix}/lib -lharfbuzz -lfreetype
EOF
}

build_one() { # label  <extra cmake args...>
    local label="$1"; shift
    local prefix="$OUT/$label"
    echo "== $label"
    rm -rf "$prefix"
    mkdir -p "$prefix"

    local ftbuild="$SRC/build-freetype-$label"
    rm -rf "$ftbuild"; mkdir -p "$ftbuild"
    cmake -G Ninja -S "$SRC/freetype-$FREETYPE_VERSION" -B "$ftbuild" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        "${FT_FLAGS[@]}" "$@" > "$ftbuild/configure.log" 2>&1 \
        || { cat "$ftbuild/configure.log"; exit 1; }
    cmake --build "$ftbuild" --target install > "$ftbuild/build.log" 2>&1 \
        || { tail -40 "$ftbuild/build.log"; exit 1; }
    echo "  freetype $FREETYPE_VERSION"

    local hbbuild="$SRC/build-harfbuzz-$label"
    rm -rf "$hbbuild"; mkdir -p "$hbbuild"
    cmake -G Ninja -S "$SRC/harfbuzz-$HARFBUZZ_VERSION" -B "$hbbuild" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_PREFIX_PATH="$prefix" \
        -DFREETYPE_LIBRARY="$prefix/lib/libfreetype.a" \
        -DFREETYPE_INCLUDE_DIRS="$prefix/include/freetype2" \
        "${HB_FLAGS[@]}" "$@" > "$hbbuild/configure.log" 2>&1 \
        || { cat "$hbbuild/configure.log"; exit 1; }
    cmake --build "$hbbuild" --target install > "$hbbuild/build.log" 2>&1 \
        || { tail -40 "$hbbuild/build.log"; exit 1; }
    echo "  harfbuzz $HARFBUZZ_VERSION"

    write_pc "$prefix"
    ls "$prefix/lib" | grep -E '\.a$' | sed 's/^/  /'
}

build_android() { # abi  triple
    local abi="$1" triple="$2"
    [ -d "$NDK" ] || { echo "error: NDK not at $NDK (set ANDROID_NDK_HOME)" >&2; exit 1; }
    build_one "$triple" \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM="android-$ANDROID_API"
}

# Matched to what SwiftPM links test bundles against, so the archives do not
# come back as "built for a newer macOS than being linked".
HOST_FLAGS=(-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0)

what="${1:-all}"

echo "FreeType $FREETYPE_VERSION, HarfBuzz $HARFBUZZ_VERSION"
fetch "$FREETYPE_URL" "$FREETYPE_SHA256" "freetype-$FREETYPE_VERSION.tar.xz"
fetch "$HARFBUZZ_URL" "$HARFBUZZ_SHA256" "harfbuzz-$HARFBUZZ_VERSION.tar.xz"
unpack "freetype-$FREETYPE_VERSION.tar.xz" "freetype-$FREETYPE_VERSION"
unpack "harfbuzz-$HARFBUZZ_VERSION.tar.xz" "harfbuzz-$HARFBUZZ_VERSION"

case "$what" in
    host)    build_one host "${HOST_FLAGS[@]}" ;;
    android) build_android arm64-v8a aarch64-linux-android
             build_android x86_64    x86_64-linux-android ;;
    all)     build_one host "${HOST_FLAGS[@]}"
             build_android arm64-v8a aarch64-linux-android
             build_android x86_64    x86_64-linux-android ;;
    *) echo "usage: build.sh [host|android|all]" >&2; exit 2 ;;
esac

echo
echo "built into $OUT"
