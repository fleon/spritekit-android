#!/bin/sh
# Builds Tools/Art/system-symbols.swift as a Mac Catalyst tool (UIKit's
# symbol sizes, not AppKit's) and runs it with the given arguments.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
sdk=$(xcrun --sdk macosx --show-sdk-path)
arch=$(uname -m)
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
xcrun swiftc -target "$arch-apple-ios18.0-macabi" -sdk "$sdk" \
    -F "$sdk/System/iOSSupport/System/Library/Frameworks" \
    -o "$build/system-symbols" "$here/system-symbols.swift"
"$build/system-symbols" "$@"
