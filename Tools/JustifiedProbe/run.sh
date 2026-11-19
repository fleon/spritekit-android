#!/bin/bash
#
# Regenerates the justified-breaking fixture from TextKit 2 (see main.swift),
# as a Mac Catalyst tool on this Mac.
#
#   Tools/JustifiedProbe/run.sh
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -O -target arm64-apple-ios17.0-macabi -sdk "$sdk" \
    -F "$sdk/System/iOSSupport/System/Library/Frameworks" -I "$sdk/System/iOSSupport/usr/include" \
    -L "$sdk/System/iOSSupport/usr/lib" -Xlinker -rpath -Xlinker /System/iOSSupport/System/Library/Frameworks \
    "$here/main.swift" -o "$work/probe"
"$work/probe" "$root/Text/Tests/Fixtures/Fonts" > "$root/Text/Tests/Fixtures/Justified/textkit2-justified.tsv"
wc -l "$root/Text/Tests/Fixtures/Justified/textkit2-justified.tsv"
