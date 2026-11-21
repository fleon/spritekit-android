#!/bin/bash
# A lock for the machine's physical test devices, shared by every session,
# worktree and game on it, so one session's install, launch or keypress never
# lands in the middle of another's run.
#
#   Scripts/device-lock.sh acquire <device> <holder> [why]   take it, or exit 1 if busy
#   Scripts/device-lock.sh wait    <device> <holder> [why]   take it, waiting until free
#   Scripts/device-lock.sh renew   <device> <holder>         keep holding (every < 20 min)
#   Scripts/device-lock.sh release <device> <holder>         give it back
#   Scripts/device-lock.sh status                            who holds what
#   Scripts/device-lock.sh run <device> <holder> [--wait] -- <command...>
#       runs the command only while holding the device: takes it (or waits
#       for it with --wait), renews it while the command runs, and releases
#       it when the command ends, however it ends. Exits 1 without running
#       anything if the device is busy. Prefer this to acquire/release.
#
# The holder is the session's name. Hold a device only while a run on it is
# going (install, launch, measure), release it right after, and never across
# a wait for the person. A lock not renewed for 30 minutes is stale and the
# next caller takes it over.
#
# The machine names its devices and where the locks live in
# ~/.config/spritekit-android/devices.env (sourced if present), which is
# also the place for what a session needs to reach each device:
#
#   SKA_DEVICES        the device names, space-separated (required)
#   SKA_DEVICE_LOCKS   where the locks live  (~/.spritekit-android/device-locks)

set -u
CONFIG="${SKA_DEVICES_CONFIG:-$HOME/.config/spritekit-android/devices.env}"
[ -f "$CONFIG" ] && . "$CONFIG"
DIR="${SKA_DEVICE_LOCKS:-$HOME/.spritekit-android/device-locks}"
DEVICES="${SKA_DEVICES:-}"
mkdir -p "$DIR"
STALE=1800
now() { date +%s; }
die() { echo "device-lock: $*" >&2; exit 2; }

device() {
    [ -n "$DEVICES" ] || die "no devices: list them as SKA_DEVICES in $CONFIG"
    local d
    for d in $DEVICES; do [ "${1:-}" = "$d" ] && { echo "$d"; return; }; done
    die "device must be one of: $DEVICES"
}

holder_of() { cat "$1/holder" 2>/dev/null | head -1; }
age_of() { echo $(( $(now) - $(stat -f %m "$1/holder" 2>/dev/null || echo 0) )); }

try_take() {
    local lock="$DIR/$1.lock" who="$2" why="$3"
    if mkdir "$lock" 2>/dev/null; then
        printf '%s\n%s\n%s\n' "$who" "$why" "$(date '+%Y-%m-%d %H:%M:%S')" > "$lock/holder"
        return 0
    fi
    [ "$(holder_of "$lock")" = "$who" ] && { touch "$lock/holder"; return 0; }
    if [ "$(age_of "$lock")" -gt "$STALE" ]; then
        echo "device-lock: taking over $1 from stale holder $(holder_of "$lock")" >&2
        rm -rf "$lock"
        try_take "$@"
        return $?
    fi
    return 1
}

busy() {
    local lock="$DIR/$1.lock"
    echo "device-lock: $1 is held by $(holder_of "$lock") ($(sed -n 2p "$lock/holder"), since $(sed -n 3p "$lock/holder"), last renewed $(( $(age_of "$lock") / 60 )) min ago)" >&2
}

cmd="${1:-status}"
case "$cmd" in
    acquire|wait)
        d="$(device "${2:-}")" || exit 2; who="${3:-}"; why="${4:-}"
        [ -n "$who" ] || die "give a holder name (your session's name)"
        if [ "$cmd" = acquire ]; then
            try_take "$d" "$who" "$why" && { echo "device-lock: $who holds $d"; exit 0; }
            busy "$d"; exit 1
        fi
        until try_take "$d" "$who" "$why"; do busy "$d"; sleep 30; done
        echo "device-lock: $who holds $d" ;;
    renew)
        d="$(device "${2:-}")" || exit 2; who="${3:-}"; lock="$DIR/$d.lock"
        [ "$(holder_of "$lock")" = "$who" ] || die "$who doesn't hold $d"
        touch "$lock/holder"; echo "device-lock: $who renewed $d" ;;
    release)
        d="$(device "${2:-}")" || exit 2; who="${3:-}"; lock="$DIR/$d.lock"
        [ -d "$lock" ] || { echo "device-lock: $d was free"; exit 0; }
        [ "$(holder_of "$lock")" = "$who" ] || die "$d is held by $(holder_of "$lock"), not $who"
        rm -rf "$lock"; echo "device-lock: $who released $d" ;;
    run)
        d="$(device "${2:-}")" || exit 2; who="${3:-}"
        [ -n "$who" ] || die "usage: run <device> <holder> [--wait] -- <command...>"
        shift 3
        waiting=0
        [ "${1:-}" = "--wait" ] && { waiting=1; shift; }
        [ "${1:-}" = "--" ] && shift
        [ $# -gt 0 ] || die "give the command to run after --"
        lock="$DIR/$d.lock"
        # Already held by this holder (acquired by hand): run under it and
        # leave it held, as it was.
        running() { local p; p=$(cat "$lock/run.pid" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
        # Held by hand under this name (and not by a run still going): run
        # under it and leave it held afterwards.
        owned=0
        [ "$(holder_of "$lock")" = "$who" ] && ! running && owned=1
        # Another `run` still going on the device (even under the same holder
        # name) counts as busy: the lock is renewable by its holder, a run
        # isn't shareable.
        if [ $waiting = 1 ]; then
            until try_take "$d" "$who" "run: $*" && ! running; do
                running && echo "device-lock: another run holds $d (pid $(cat "$lock/run.pid"))" >&2 || busy "$d"
                sleep 30
            done
        else
            try_take "$d" "$who" "run: $*" || { busy "$d"; echo "device-lock: not running it" >&2; exit 1; }
            if running; then echo "device-lock: another run holds $d (pid $(cat "$lock/run.pid")); not running it" >&2; exit 1; fi
        fi
        echo $$ > "$lock/run.pid"
        echo "device-lock: $who holds $d for: $*" >&2
        # Renews every 10 minutes. It holds none of the caller's output (so a
        # pipe on `run` ends with the command) and takes its sleep with it
        # when it's stopped.
        (
            exec </dev/null >/dev/null 2>&1
            trap 'kill "$s" 2>/dev/null; exit 0' TERM
            while :; do
                sleep 600 & s=$!; wait "$s"
                [ "$(holder_of "$lock")" = "$who" ] && touch "$lock/holder" || exit 0
            done
        ) &
        renewer=$!
        cleanup() {
            kill "$renewer" 2>/dev/null
            [ "$(cat "$lock/run.pid" 2>/dev/null)" = "$$" ] && rm -f "$lock/run.pid"
            [ $owned = 0 ] && [ "$(holder_of "$lock")" = "$who" ] && rm -rf "$lock" && echo "device-lock: $who released $d" >&2
        }
        trap cleanup EXIT
        trap 'exit 130' INT TERM HUP
        "$@"
        exit $? ;;
    status)
        [ -n "$DEVICES" ] || die "no devices: list them as SKA_DEVICES in $CONFIG"
        for d in $DEVICES; do
            lock="$DIR/$d.lock"
            if [ -d "$lock" ]; then busy "$d" 2>&1; else echo "device-lock: $d is free"; fi
        done ;;
    *) die "unknown command $cmd" ;;
esac
