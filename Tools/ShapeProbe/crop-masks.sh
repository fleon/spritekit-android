#!/bin/bash
#
# Measures SKCropNode masks as an SKView draws them on screen
# (crop-masks.swift): screenshots a simulator of its own and prints, for
# each case, the cropped white sprite's brightness every 20 points across
# a mask whose alpha runs 0 → 1. A ramp means SpriteKit multiplies by the
# mask; a jump to 1.00 means it clips by it, all or nothing.
#
#   Tools/ShapeProbe/crop-masks.sh                   # iPhone 17 Pro, 3x
set -eu
device="${1:-iPhone 17 Pro}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
mkdir -p "$work/App.app"
cp "$here/Info.plist" "$work/App.app/Info.plist"
xcrun -sdk iphonesimulator swiftc -parse-as-library -module-name App \
    -target arm64-apple-ios18.0-simulator -O "$here/crop-masks.swift" -o "$work/App.app/App"
udid="$(xcrun simctl create "crop-probe-$$" "$device")"
trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1; xcrun simctl delete "$udid" >/dev/null 2>&1; rm -rf "$work"' EXIT
xcrun simctl boot "$udid"
xcrun simctl install "$udid" "$work/App.app"
xcrun simctl launch "$udid" local.probe.shapeedges >/dev/null
sleep 4
xcrun simctl io "$udid" screenshot "$work/shot.png" >/dev/null 2>&1
sips -s format bmp "$work/shot.png" --out "$work/shot.bmp" >/dev/null
names="$(sed -n 's/^ *("\([^"]*\)", .*/\1/p' "$here/crop-masks.swift")"
python3 -I - "$work/shot.bmp" "$names" <<'EOF'
import struct, sys
data = open(sys.argv[1], 'rb').read()
offset = struct.unpack_from('<I', data, 10)[0]
width, height = struct.unpack_from('<ii', data, 18)
bpp = struct.unpack_from('<H', data, 28)[0] // 8
row = (width * bpp + 3) & ~3
def red(x, y):  # y from the top
    yy = height - 1 - y if height > 0 else y
    i = offset + abs(yy) * row + x * bpp
    return data[i + 2] / 255
scale = width / 402  # iPhone 17 Pro: 402 points wide
names = sys.argv[2].split('\n')
for index, name in enumerate(names):
    y = int((120 + index * 50) * scale)
    xs = [int((20 + 1 + p) * scale) for p in range(0, 200, 20)]
    print(f"{name}: " + ' '.join(f"{red(x, y):.2f}" for x in xs))
EOF
