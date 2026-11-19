#!/bin/bash
#
# Measures how SpriteKit tints (see main.swift): on a simulator of its own
# (a device-scale SKView), or with --mac, in a windowless SKView on this Mac.
#
#   Tools/TintProbe/run.sh                 # iPhone 17 Pro, 3x
#   Tools/TintProbe/run.sh --mac
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
if [ "${1:-}" = "--mac" ]; then
    trap 'rm -rf "$work"' EXIT
    xcrun swiftc -parse-as-library -O "$here/main.swift" -o "$work/probe"
    "$work/probe"
    exit 0
fi
device="${1:-iPhone 17 Pro}"
mkdir -p "$work/App.app"
cp "$here/Info.plist" "$work/App.app/Info.plist"
xcrun -sdk iphonesimulator swiftc -parse-as-library -module-name App \
    -target arm64-apple-ios18.0-simulator -O "$here/main.swift" -o "$work/App.app/App"
udid="$(xcrun simctl create "tint-probe-$$" "$device")"
trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1; xcrun simctl delete "$udid" >/dev/null 2>&1; rm -rf "$work"' EXIT
xcrun simctl boot "$udid"
xcrun simctl install "$udid" "$work/App.app"
xcrun simctl launch "$udid" local.probe.tint >/dev/null
out="$(xcrun simctl get_app_container "$udid" local.probe.tint data)/Documents/probe.txt"
for _ in $(seq 90); do [ -s "$out" ] && break; sleep 1; done
cat "$out"
