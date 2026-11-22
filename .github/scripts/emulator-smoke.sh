#!/bin/bash
#
# Installs the template check's APK (Scripts/check-template.sh) on the
# running emulator, launches it, and waits for its first scene's message in
# logcat (Templates/Check/Source/TitleScene.swift). Leaves logcat.txt and
# screen.png behind either way.
#
#   .github/scripts/emulator-smoke.sh <apk>
#
# A freshly booted emulator's launcher can still be coming up when the app
# starts: it then takes the foreground over the app (opening its long-press
# menu for the Menu key the emulator action sends to unlock), the app stops
# before drawing, and its first scene never shows. So the launcher is let
# settle before the launch, and the app is brought back once if it loses the
# foreground anyway.

set -euo pipefail

apk="$1"
package="com.example.templatecheck"
activity="$package/.MainActivity"
message="template-check: first scene shown"
seconds=180

# The activity that has the foreground, as `package/.Activity`, or nothing.
resumed() {
    adb shell dumpsys activity activities 2>/dev/null \
        | grep -m1 -E 'topResumedActivity|mResumedActivity' \
        | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+' || true
}

adb wait-for-device

# Wait for the home screen to be the resumed activity, then close anything
# open over it (the long-press menu) and go home once more.
home=$(adb shell cmd package resolve-activity --brief \
    -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null \
    | tail -1 | tr -d '\r' | cut -d/ -f1 || true)
for ((i = 1; i <= 60; i++)); do
    if [ -n "$home" ] && resumed | grep -qF "$home/"; then
        break
    fi
    sleep 1
done
echo "home screen (${home:-unknown}) resumed after ${i}s"
adb shell input keyevent KEYCODE_BACK
adb shell input keyevent KEYCODE_HOME
sleep 3

adb install -r "$apk"
adb logcat -c
adb shell am start -W -n "$activity"

shown=""
relaunched=""
for ((i = 1; i <= seconds; i++)); do
    log=$(adb logcat -d)
    if grep -qF "$message" <<< "$log"; then
        shown="$i"
        break
    fi
    if grep -qE "FATAL EXCEPTION|Fatal signal|Couldn't load library" <<< "$log"; then
        echo "the app crashed, or its native library didn't load" >&2
        break
    fi
    # Lost the foreground before its first scene: bring it back, once.
    if [ -z "$relaunched" ] && [ "$i" -ge 10 ] && ! resumed | grep -qF "$package/"; then
        echo "the app lost the foreground to $(resumed) after ${i}s; bringing it back" >&2
        adb shell input keyevent KEYCODE_BACK
        adb shell am start -W -n "$activity"
        relaunched="$i"
    fi
    sleep 1
done

adb logcat -d > logcat.txt || true
adb exec-out screencap -p > screen.png || true

if [ -z "$shown" ]; then
    echo "no \"$message\" in logcat after ${i}s (foreground: $(resumed))" >&2
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
echo "first scene shown ${shown}s after launch${relaunched:+ (brought back to the front at ${relaunched}s)}"
