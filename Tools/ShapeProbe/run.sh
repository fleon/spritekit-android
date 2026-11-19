#!/bin/bash
#
# Measures how SpriteKit draws shape nodes on a device-scale screen: builds
# a one-file iOS app, runs it on a simulator of its own, and prints what it
# read back through `SKView.texture(from:)` (strokes across a vertical line
# at several widths and node scales, a fill's edge, crop masks).
#
#   Tools/ShapeProbe/run.sh                      # iPhone 17 Pro, 3x
#   Tools/ShapeProbe/run.sh "iPad Air 11-inch (M4)"  # 2x
#
# A windowless SKRenderer on a Mac draws strokes softer than any device:
# measure shape edges here.
set -eu
device="${1:-iPhone 17 Pro}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
mkdir -p "$work/App.app"
cp "$here/Info.plist" "$work/App.app/Info.plist"
xcrun -sdk iphonesimulator swiftc -parse-as-library -module-name App \
    -target arm64-apple-ios18.0-simulator -O "$here/main.swift" -o "$work/App.app/App"
udid="$(xcrun simctl create "shape-probe-$$" "$device")"
trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1; xcrun simctl delete "$udid" >/dev/null 2>&1; rm -rf "$work"' EXIT
xcrun simctl boot "$udid"
xcrun simctl install "$udid" "$work/App.app"
xcrun simctl launch "$udid" local.probe.shapeedges >/dev/null
out="$(xcrun simctl get_app_container "$udid" local.probe.shapeedges data)/Documents/probe.txt"
for _ in $(seq 60); do [ -s "$out" ] && break; sleep 1; done
cat "$out"
