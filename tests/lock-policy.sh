#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixtures="$root/tests/fixtures/lock-policy"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export LOCK_POLICY_LOG="$work/log"
export PATH="$fixtures:$PATH"

assert_log() {
    expected=$1
    actual=$(cat "$LOCK_POLICY_LOG")
    [ "$actual" = "$expected" ] || {
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        exit 1
    }
}

: > "$LOCK_POLICY_LOG"
"$root/dist/libexec/lock-cmd.sh"
assert_log 'vigil-lock:--wait --no-warn
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'

: > "$LOCK_POLICY_LOG"
VIGIL_IDLE_WARNING_SECONDS=7 "$root/dist/libexec/lock-cmd.sh" --idle
assert_log 'vigil-lock:--wait --warn 7
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'

: > "$LOCK_POLICY_LOG"
LOCK_POLICY_VIGIL_STATUS=3 "$root/dist/libexec/lock-cmd.sh" --idle
assert_log 'vigil-lock:--wait --warn 10'

echo "lock policy routing is correct"
