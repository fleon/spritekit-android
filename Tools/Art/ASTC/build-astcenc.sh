#!/usr/bin/env bash
#
# Builds Arm's ASTC encoder, which compress.js compresses the runtime's
# packed pages with; compress.js runs this itself the first time a checkout
# needs the encoder. Homebrew has no formula for it, so this fetches the
# pinned release's source, checks its hash and builds the host's binary into
# Tools/Art/ASTC/out/astcenc (src/ and out/ are gitignored).
#
#   Tools/Art/ASTC/build-astcenc.sh
#
# Needs cmake, ninja and a C++ compiler (Xcode's command line tools).
set -euo pipefail

for tool in cmake ninja c++; do
    if ! command -v "$tool" >/dev/null; then
        echo "build-astcenc.sh: needs $tool (brew install cmake ninja; xcode-select --install for c++)" >&2
        exit 1
    fi
done

VERSION="5.7.1"
SHA256="37ff3928c4c156fb3ac0d1adb5df144ff9c5cdbc8a8e1ffeb20229cc7f35c767"
URL="https://github.com/ARM-software/astc-encoder/archive/refs/tags/$VERSION.tar.gz"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src"
OUT="$HERE/out"
TARBALL="$SRC/astc-encoder-$VERSION.tar.gz"
mkdir -p "$SRC" "$OUT"

if [ ! -f "$TARBALL" ] || [ "$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)" != "$SHA256" ]; then
    echo "fetching astc-encoder $VERSION"
    curl -fsSL -o "$TARBALL" "$URL"
    have="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
    if [ "$have" != "$SHA256" ]; then
        echo "astc-encoder $VERSION: hash $have, expected $SHA256" >&2
        rm -f "$TARBALL"
        exit 1
    fi
fi

TREE="$SRC/astc-encoder-$VERSION"
[ -d "$TREE" ] || tar -xzf "$TARBALL" -C "$SRC"

case "$(uname -m)" in
    arm64) ISA=(-DASTCENC_ISA_NEON=ON) ;;
    *) ISA=(-DASTCENC_ISA_AVX2=ON) ;;
esac

BUILD="$SRC/build-$VERSION"
cmake -S "$TREE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$BUILD/install" "${ISA[@]}" \
    -DASTCENC_UNIVERSAL_BUILD=OFF -DASTCENC_CLI=ON >/dev/null
cmake --build "$BUILD" --target install >/dev/null

BIN="$(find "$BUILD/install" -type f -name 'astcenc-*' -perm -u+x | head -1)"
[ -n "$BIN" ] || { echo "no astcenc binary under $BUILD/install" >&2; exit 1; }
cp "$BIN" "$OUT/astcenc"
echo "astcenc $VERSION -> $OUT/astcenc"
