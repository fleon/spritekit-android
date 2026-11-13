# Pinned versions of the two C libraries the text stack is built on.
#
# Both are fetched as release tarballs and checked against these hashes
# before anything is unpacked. Nothing binary is committed to the repo.

FREETYPE_VERSION=2.15.0
FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
FREETYPE_SHA256=93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5

HARFBUZZ_VERSION=15.1.0
HARFBUZZ_URL="https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
HARFBUZZ_SHA256=0fc7c565443a5f4be7da65ac5ee5bd737d9b158dc908708b7689a0a5796b0c8d

# The Android API level the Swift SDK targets.
ANDROID_API=23
