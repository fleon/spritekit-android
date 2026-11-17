#!/bin/bash
# A pool of Android emulators that several sessions can share, one each.
#
#   eval "$(Scripts/emulators.sh acquire <owner> [minutes])"
#       Takes a free slot for <owner> (or renews the one it already holds),
#       boots its emulator on the host GPU if it isn't running, waits for it,
#       and prints `export ANDROID_SERIAL=emulator-<port>`, which every adb,
#       Gradle and ddms call after it then targets. Exits 2 when every slot
#       is held.
#   Scripts/emulators.sh release <owner>
#       Shuts that owner's emulator down and frees its slot.
#   Scripts/emulators.sh status
#       Who holds which slot, until when, and whether it's up.
#
# A slot is lent for a lease (30 minutes unless asked otherwise) that every
# `acquire` by the same owner renews, so acquire before each emulator step
# and release after it. Every `acquire` and `status` first shuts down each
# slot whose lease has lapsed and frees it, so a session that stops without
# releasing (or a crash) holds no emulator, and no memory, for long.
#
# Each slot is an AVD of its own (`<prefix><n>`, made here on first use from
# the template below) on console port 5556, 5558, 5560 or 5562, so
# slots never share data, installs or system properties. Emulators start on
# the host GPU (`-gpu host`): left to choose, one fell back to SwiftShader at
# about two frames a second. A released slot's emulator is shut down, so idle
# slots hold no memory; a boot from cold takes about 15 seconds.
#
# State lives outside every checkout, so every worktree of every game on the
# machine shares one pool. The machine can say where, and what the pool's
# AVDs are called, in ~/.config/spritekit-android/pool.env (sourced if
# present), so a pool made before this script had its defaults keeps its
# AVDs and leases:
#
#   SKA_POOL_STATE        where leases live   (~/.spritekit-android/emulators)
#   SKA_POOL_AVD_PREFIX   the slots' AVDs     (spritekit_pool_)
#   SKA_POOL_PROPERTIES   system-property prefixes cleared for each new owner,
#                         space-separated     (debug.spritekit.): every game's
#                         `debug.<AppIdentity.key>.` belongs here
#
# Set SKA_EMULATOR_WINDOW=0 to boot without a window.
set -euo pipefail

POOL_CONFIG="$HOME/.config/spritekit-android/pool.env"
# shellcheck disable=SC1090
[ -f "$POOL_CONFIG" ] && . "$POOL_CONFIG"

SLOTS=4
FIRST_PORT=5556
DEFAULT_MINUTES=30
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
EMULATOR="$SDK/emulator/emulator"
AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
STATE="${SKA_POOL_STATE:-$HOME/.spritekit-android/emulators}"
AVD_PREFIX="${SKA_POOL_AVD_PREFIX:-spritekit_pool_}"
PROPERTY_PREFIXES="${SKA_POOL_PROPERTIES:-debug.spritekit.}"
LOCK="$STATE/.lock"

mkdir -p "$STATE"

die() { echo "emulators: $*" >&2; exit 1; }
now() { date +%s; }
port_of() { echo $((FIRST_PORT + 2 * ($1 - 1))); }
serial_of() { echo "emulator-$(port_of "$1")"; }
avd_of() { echo "$AVD_PREFIX$1"; }

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
is_up() { bounded 5 "$ADB" -s "$(serial_of "$1")" get-state >/dev/null 2>&1; }

lease() { # slot owner minutes
    echo "$2" > "$STATE/slot-$1.owner"
    echo $(( $(now) + $3 * 60 )) > "$STATE/slot-$1.until"
}
free() { rm -f "$STATE/slot-$1.owner" "$STATE/slot-$1.until"; }

# The AVD: a Pixel 6, Android 17, arm64, Google APIs, always on the host GPU.
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
avd.ini.displayname=SpriteKit Pool $n
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

# The slot's emulator process, which can outlive adb's view of it: a qemu
# that hung on shutdown once held its AVD's locks and stopped the slot's next
# boot, while adb already reported the device gone.
qemu_of() { pgrep -f "qemu-system.*-avd $(avd_of "$1") " 2>/dev/null || true; }

# Runs a command for at most $1 seconds: adb waits for ever on an emulator
# whose console has hung (`emu kill` did, on a frozen qemu).
bounded() {
    local seconds=$1 pid
    shift
    "$@" & pid=$!
    for _ in $(seq 1 $((seconds * 5))); do
        kill -0 "$pid" 2>/dev/null || { wait "$pid"; return; }
        sleep 0.2
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 124
}

stop_slot() {
    local n=$1 serial
    serial=$(serial_of "$n")
    if is_up "$n"; then
        bounded 10 "$ADB" -s "$serial" emu kill >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do [ -z "$(qemu_of "$n")" ] && break; sleep 1; done
    fi
    if [ -n "$(qemu_of "$n")" ]; then
        pkill -TERM -f "qemu-system.*-avd $(avd_of "$n") " 2>/dev/null || true
        for _ in $(seq 1 10); do [ -z "$(qemu_of "$n")" ] && break; sleep 1; done
    fi
    if [ -n "$(qemu_of "$n")" ]; then
        echo "emulators: slot $n's emulator hung; killing it" >&2
        pkill -KILL -f "qemu-system.*-avd $(avd_of "$n") " 2>/dev/null || true
        sleep 1
        # A killed emulator leaves its locks behind, and the next boot of
        # this AVD would refuse to start.
        rm -f "$AVD_HOME/$(avd_of "$n").avd/"*.lock 2>/dev/null || true
    fi
}

# A slot handed to a new owner starts as the AVD defines it. Screen overrides
# (`wm size`, `wm density`) survive reboots in the AVD's data, and one session
# left a 402-point screen for the next; the games' `debug.<key>.*` properties last
# until a reboot. Every new lease clears them.
clean_slot() {
    local serial
    serial=$(serial_of "$1")
    "$ADB" -s "$serial" shell wm size reset >/dev/null 2>&1 || true
    "$ADB" -s "$serial" shell wm density reset >/dev/null 2>&1 || true
    local prefix pattern
    for prefix in $PROPERTY_PREFIXES; do
        pattern="$(printf '%s' "$prefix" | sed 's/\./\\./g')"
        "$ADB" -s "$serial" shell "for p in \$(getprop | grep -o '^\[$pattern[^]]*' | tr -d '['); do setprop \"\$p\" ''; done" >/dev/null 2>&1 || true
    done
}

boot_slot() {
    local n=$1 fresh=${2:-0} serial window=()
    serial=$(serial_of "$n")
    ensure_avd "$n"
    if ! is_up "$n"; then
        # An emulator adb can't see but that is still running (hung) would
        # hold the AVD's locks: stop it before booting a new one.
        [ -n "$(qemu_of "$n")" ] && stop_slot "$n"
        [ "${SKA_EMULATOR_WINDOW:-1}" = 0 ] && window=(-no-window)
        nohup "$EMULATOR" -avd "$(avd_of "$n")" -port "$(port_of "$n")" -gpu host \
            -no-snapshot -no-boot-anim -no-audio ${window[@]+"${window[@]}"} \
            > "$STATE/slot-$n.log" 2>&1 &
    fi
    for _ in $(seq 1 120); do
        if [ "$("$ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
            if "$ADB" -s "$serial" shell dumpsys SurfaceFlinger 2>/dev/null | grep -q '^GLES.*SwiftShader'; then
                echo "emulators: slot $n came up on SwiftShader, not the host GPU" >&2
            fi
            [ "$fresh" = 1 ] && clean_slot "$n"
            return 0
        fi
        sleep 2
    done
    die "slot $n ($serial) did not boot; see $STATE/slot-$n.log"
}

# Shuts down and frees every slot whose lease has lapsed, except `keep`'s
# (an owner coming back renews its own). Call with the lock held.
reap() {
    local keep=${1:-} n owner
    for n in $(seq 1 $SLOTS); do
        owner=$(owner_of "$n")
        [ -n "$owner" ] && [ "$owner" != "$keep" ] || continue
        if [ "$(until_of "$n")" -lt "$(now)" ]; then
            echo "emulators: slot $n's lease to $owner lapsed; shutting it down" >&2
            stop_slot "$n"
            free "$n"
        fi
    done
}

acquire() {
    local owner=${1:?owner} minutes=${2:-$DEFAULT_MINUTES} n slot="" fresh=0
    lock
    reap "$owner"
    for n in $(seq 1 $SLOTS); do
        [ "$(owner_of "$n")" = "$owner" ] && { slot=$n; break; }
    done
    if [ -z "$slot" ]; then
        for n in $(seq 1 $SLOTS); do
            [ -z "$(owner_of "$n")" ] && { slot=$n; fresh=1; break; }
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
    boot_slot "$slot" "$fresh"
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
    status) lock; reap; unlock; status ;;
    *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
