#!/bin/bash
# A pool of Android emulators that several sessions can share, one each.
#
#   eval "$(Android/Scripts/emulators.sh acquire <owner> [minutes])"
#       Takes a free slot for <owner> (or renews the one it already holds),
#       boots its emulator on the host GPU if it isn't running, waits for it,
#       and prints `export ANDROID_SERIAL=emulator-<port>`, which every adb,
#       Gradle and ddms call after it then targets. Exits 2 when every slot
#       is held.
#   Android/Scripts/emulators.sh release <owner>
#       Shuts that owner's emulator down and frees its slot.
#   Android/Scripts/emulators.sh status
#       Who holds which slot, until when, and whether it's up.
#
# A slot is lent for a lease (60 minutes unless asked otherwise) that every
# `acquire` by the same owner renews, so acquire before each emulator step.
# A lapsed lease is taken back by the next acquire that needs a slot, so a
# session that ends without releasing doesn't hold one for good.
#
# Each slot is an AVD of its own (`switchlings_pool_<n>`, made here on first
# use from the template below) on console port 5556, 5558, 5560 or 5562, so
# slots never share data, installs or system properties. Emulators start on
# the host GPU (`-gpu host`): left to choose, one fell back to SwiftShader at
# about two frames a second. A released slot's emulator is shut down, so idle
# slots hold no memory; a boot from cold takes about 15 seconds.
#
# State lives outside every checkout, in ~/.switchlings/emulators, so all
# worktrees share one pool. Set SWITCHLINGS_EMULATOR_WINDOW=0 to boot
# without a window.
set -euo pipefail

SLOTS=4
FIRST_PORT=5556
DEFAULT_MINUTES=60
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
EMULATOR="$SDK/emulator/emulator"
AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
STATE="$HOME/.switchlings/emulators"
LOCK="$STATE/.lock"

mkdir -p "$STATE"

die() { echo "emulators: $*" >&2; exit 1; }
now() { date +%s; }
port_of() { echo $((FIRST_PORT + 2 * ($1 - 1))); }
serial_of() { echo "emulator-$(port_of "$1")"; }
avd_of() { echo "switchlings_pool_$1"; }

# One caller at a time changes the pool. mkdir is atomic; a lock older than a
# minute was left by a caller that died, and is broken.
lock() {
    local tries=0
    until mkdir "$LOCK" 2>/dev/null; do
        if [ -d "$LOCK" ] && [ $(( $(now) - $(stat -f %m "$LOCK") )) -gt 60 ]; then
            rmdir "$LOCK" 2>/dev/null || true
            continue
        fi
        tries=$((tries + 1))
        [ $tries -gt 300 ] && die "the pool's lock is busy"
        sleep 0.2
    done
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
}
unlock() { rmdir "$LOCK" 2>/dev/null || true; trap - EXIT; }

owner_of() { cat "$STATE/slot-$1.owner" 2>/dev/null || true; }
until_of() { cat "$STATE/slot-$1.until" 2>/dev/null || echo 0; }
is_up() { "$ADB" -s "$(serial_of "$1")" get-state >/dev/null 2>&1; }

lease() { # slot owner minutes
    echo "$2" > "$STATE/slot-$1.owner"
    echo $(( $(now) + $3 * 60 )) > "$STATE/slot-$1.until"
}
free() { rm -f "$STATE/slot-$1.owner" "$STATE/slot-$1.until"; }

# The AVD, as the shared switchlings_shell was set up (a Pixel 6, Android 17,
# arm64, Google APIs), but always on the host GPU.
ensure_avd() {
    local n=$1 avd dir
    avd=$(avd_of "$n")
    dir="$AVD_HOME/$avd.avd"
    [ -f "$dir/config.ini" ] && return
    [ -d "$SDK/system-images/android-37.0/google_apis/arm64-v8a" ] \
        || die "missing system image system-images;android-37.0;google_apis;arm64-v8a"
    mkdir -p "$dir"
    cat > "$AVD_HOME/$avd.ini" <<EOF
avd.ini.encoding=UTF-8
path=$dir
path.rel=avd/$avd.avd
target=android-37
EOF
    cat > "$dir/config.ini" <<EOF
AvdId=$avd
abi.type=arm64-v8a
avd.ini.displayname=Switchlings Pool $n
avd.ini.encoding=UTF-8
disk.dataPartition.size=6442450944
hw.accelerometer=yes
hw.audioInput=no
hw.audioOutput=no
hw.battery=yes
hw.camera.back=none
hw.camera.front=none
hw.cpu.arch=arm64
hw.cpu.ncore=4
hw.dPad=no
hw.device.manufacturer=Google
hw.device.name=pixel_6
hw.gps=yes
hw.gpu.enabled=yes
hw.gpu.mode=host
hw.gyroscope=yes
hw.keyboard=yes
hw.lcd.density=420
hw.lcd.height=2400
hw.lcd.width=1080
hw.mainKeys=no
hw.ramSize=4096
hw.sdCard=no
hw.trackBall=no
image.sysdir.1=system-images/android-37.0/google_apis/arm64-v8a/
showDeviceFrame=no
tag.display=Google APIs
tag.id=google_apis
tag.ids=google_apis
target=android-37
EOF
}

stop_slot() {
    local serial
    serial=$(serial_of "$1")
    is_up "$1" || return 0
    "$ADB" -s "$serial" emu kill >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do is_up "$1" || return 0; sleep 1; done
    pkill -f "qemu-system.*-avd $(avd_of "$1") " 2>/dev/null || true
}

boot_slot() {
    local n=$1 serial window=()
    serial=$(serial_of "$n")
    ensure_avd "$n"
    if ! is_up "$n"; then
        [ "${SWITCHLINGS_EMULATOR_WINDOW:-1}" = 0 ] && window=(-no-window)
        nohup "$EMULATOR" -avd "$(avd_of "$n")" -port "$(port_of "$n")" -gpu host \
            -no-snapshot -no-boot-anim -no-audio ${window[@]+"${window[@]}"} \
            > "$STATE/slot-$n.log" 2>&1 &
    fi
    for _ in $(seq 1 120); do
        if [ "$("$ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
            if "$ADB" -s "$serial" shell dumpsys SurfaceFlinger 2>/dev/null | grep -q '^GLES.*SwiftShader'; then
                echo "emulators: slot $n came up on SwiftShader, not the host GPU" >&2
            fi
            return 0
        fi
        sleep 2
    done
    die "slot $n ($serial) did not boot; see $STATE/slot-$n.log"
}

acquire() {
    local owner=${1:?owner} minutes=${2:-$DEFAULT_MINUTES} n slot=""
    lock
    for n in $(seq 1 $SLOTS); do
        [ "$(owner_of "$n")" = "$owner" ] && { slot=$n; break; }
    done
    if [ -z "$slot" ]; then
        for n in $(seq 1 $SLOTS); do
            [ -z "$(owner_of "$n")" ] && { slot=$n; break; }
        done
    fi
    if [ -z "$slot" ]; then
        for n in $(seq 1 $SLOTS); do
            if [ "$(until_of "$n")" -lt "$(now)" ]; then
                echo "emulators: slot $n's lease to $(owner_of "$n") lapsed; taking it" >&2
                stop_slot "$n"
                slot=$n
                break
            fi
        done
    fi
    if [ -z "$slot" ]; then
        unlock
        status >&2
        echo "emulators: every slot is held" >&2
        exit 2
    fi
    lease "$slot" "$owner" "$minutes"
    unlock
    boot_slot "$slot"
    echo "export ANDROID_SERIAL=$(serial_of "$slot")"
}

release() {
    local owner=${1:?owner} n found=0
    lock
    for n in $(seq 1 $SLOTS); do
        if [ "$(owner_of "$n")" = "$owner" ]; then
            stop_slot "$n"
            free "$n"
            found=1
            echo "emulators: released slot $n" >&2
        fi
    done
    unlock
    [ $found = 1 ] || echo "emulators: $owner holds no slot" >&2
}

status() {
    local n owner left
    for n in $(seq 1 $SLOTS); do
        owner=$(owner_of "$n")
        if [ -n "$owner" ]; then
            left=$(( ($(until_of "$n") - $(now)) / 60 ))
            [ $left -lt 0 ] && left="lapsed" || left="${left} min left"
        else
            owner="free"; left=""
        fi
        printf 'slot %d  %-14s  %-18s %s %s\n' "$n" "$(serial_of "$n")" "$owner" \
            "$(is_up "$n" && echo up || echo down)" "$left"
    done
}

case "${1:-}" in
    acquire) shift; acquire "$@" ;;
    release) shift; release "$@" ;;
    status) status ;;
    *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
