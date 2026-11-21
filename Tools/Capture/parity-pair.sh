#!/bin/bash
#
# One state of a game side by side: a pool emulator's screen beside an iOS
# simulator's, with a picture of where they differ and a score (the mean
# difference over a 90-pixel-wide grid, 0 to 100; lower is closer). Size the
# emulator as the simulator's device first (`adb shell wm size <w>x<h>`,
# `wm density <dpi>`, and the device's `-SafeAreaInsets`), and launch both
# with the same `-RandomSeed`, sound and music off, in the same state.
#
#   Tools/Capture/parity-pair.sh <state> <simulator-udid> [out-dir]
#
# ANDROID_SERIAL names the emulator. Writes <out>/<state>.png (Android |
# iPhone | difference) and appends "<state> <score>" to <out>/scores.txt;
# <out> defaults to Android/Out/parity under the current directory.
set -euo pipefail
state="$1"; sim="$2"; out="${3:-Android/Out/parity}"
mkdir -p "$out/shots"
adb exec-out screencap -p > "$out/shots/$state-android.png"
xcrun simctl io "$sim" screenshot "$out/shots/$state-iphone.png" >/dev/null 2>&1
python3 - "$out" "$state" <<'PY'
import sys
from PIL import Image, ImageChops
out, state = sys.argv[1], sys.argv[2]
a = Image.open(f"{out}/shots/{state}-android.png").convert("RGB")
i = Image.open(f"{out}/shots/{state}-iphone.png").convert("RGB")
W = 360
size = (W, round(W * i.height / i.width))
a, i = a.resize(size, Image.LANCZOS), i.resize(size, Image.LANCZOS)
diff = ImageChops.difference(a, i)
small = (90, round(90 * size[1] / size[0]))
d = ImageChops.difference(a.resize(small, Image.BOX), i.resize(small, Image.BOX)).convert("L")
score = sum(d.getdata()) / (small[0] * small[1]) / 2.55
pair = Image.new("RGB", (W * 3 + 16, size[1]), (255, 255, 255))
pair.paste(a, (0, 0)); pair.paste(i, (W + 8, 0)); pair.paste(diff.point(lambda v: min(255, v * 3)), (2 * W + 16, 0))
pair.save(f"{out}/{state}.png")
with open(f"{out}/scores.txt", "a") as f: f.write(f"{state} {score:.2f}\n")
print(f"{state} {score:.2f}")
PY
