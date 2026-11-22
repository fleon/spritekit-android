#!/bin/bash
#
# Installs the template check's APK (Scripts/check-template.sh) on the
# running emulator, launches it, and waits for its first scene's message in
# logcat (Templates/Check/Source/TitleScene.swift). Leaves logcat.txt and
# screen.png behind either way.
#
#   .github/scripts/emulator-smoke.sh <apk>

set -euo pipefail

apk="$1"
package="com.example.templatecheck"
message="template-check: first scene shown"
seconds=180

adb wait-for-device
adb install -r "$apk"
adb logcat -c
adb shell am start -W -n "$package/.MainActivity"

shown=""
for ((i = 1; i <= seconds; i++)); do
    if adb logcat -d | grep -qF "$message"; then
        shown="$i"
        break
    fi
    if adb logcat -d | grep -qE "FATAL EXCEPTION|Fatal signal|Couldn't load library"; then
        echo "the app crashed, or its native library didn't load" >&2
        break
    fi
    sleep 1
done

adb logcat -d > logcat.txt || true
adb exec-out screencap -p > screen.png || true

if [ -z "$shown" ]; then
    echo "no \"$message\" in logcat after ${i}s" >&2
    tail -200 logcat.txt >&2
    exit 1
fi
# Still running a few seconds on: the scene didn't take the app down with it.
sleep 5
if ! adb shell pidof "$package" >/dev/null; then
    echo "the app stopped after its first scene" >&2
    tail -200 logcat.txt >&2
    exit 1
fi
echo "first scene shown ${shown}s after launch"
