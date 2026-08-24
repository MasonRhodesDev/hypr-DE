#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixtures="$root/tests/fixtures/lock-policy"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export LOCK_POLICY_LOG="$work/log"
export PATH="$fixtures:$PATH"
export XDG_RUNTIME_DIR="$work"
marker="$work/hypr-de-lock-failed"
# The locker sets LockedHint asynchronously, so a failed lock waits for it
# before escalating. One try keeps the failure cases fast.
export HYPR_DE_LOCK_VERIFY_TRIES=1

run_lock() {
    status=0
    "$root/dist/libexec/lock-cmd.sh" "$@" 2>>"$work/stderr" || status=$?
}
assert_status() {
    [ "$status" = "$1" ] || { echo "expected exit $1, got $status" >&2; exit 1; }
}
assert_marker() {
    if [ "$1" = yes ] && [ ! -e "$marker" ]; then
        echo "expected the lock-failure marker to exist" >&2; exit 1
    fi
    if [ "$1" = no ] && [ -e "$marker" ]; then
        echo "expected no lock-failure marker" >&2; exit 1
    fi
}

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

# --- fail-closed escalation (a lock request must never leave the session
# --- unlocked; see issue #10). Each rung is asserted on its own.

# The transient scope cannot start: fall back to an unscoped locker rather
# than returning to hypridle with the session wide open.
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_SCOPE_STATUS=1 run_lock
assert_status 0
assert_log 'systemd-run:scope-failed
vigil-lock:--wait --no-warn
hyprctl:dispatch hl.dsp.dpms({ action = '"'"'on'"'"' })'
assert_marker no

# vigil-lock itself is broken: use any other installed locker before giving up.
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_VIGIL_STATUS=1 \
    PATH="$root/tests/fixtures/lock-policy-fallback:$PATH" \
    HYPR_DE_LOCK_FALLBACKS='swaylock -f' run_lock
assert_status 0
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
swaylock:-f
hyprctl:dispatch hl.dsp.dpms({ action = '"'"'on'"'"' })'
assert_marker no

# Nothing can lock: terminate the session instead of handing back an exposed
# desktop that hypridle is about to blank into looking locked.
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_VIGIL_STATUS=1 HYPR_DE_LOCK_FALLBACKS='' run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'
assert_marker yes

# ...unless the operator opted out, in which case the session stays up but is
# marked failed so nothing disguises it as locked.
: > "$LOCK_POLICY_LOG"
rm -f "$marker"
LOCK_POLICY_VIGIL_STATUS=1 HYPR_DE_LOCK_FALLBACKS='' \
    HYPR_DE_LOCK_FAILSAFE=warn run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn'
assert_marker yes

# A later successful lock clears the marker.
: > "$LOCK_POLICY_LOG"
run_lock
assert_status 0
assert_marker no

# The idle path still treats "user came back" as success, not as a failure to
# escalate: one attempt, no retry, no fallback, no terminate.
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_VIGIL_STATUS=3 run_lock --idle
assert_status 0
assert_log 'vigil-lock:--wait --warn 10'
assert_marker no

# The blanking listener must not turn a failed lock into a fake locked screen.
: > "$LOCK_POLICY_LOG"
: > "$marker"
"$root/dist/libexec/dpms-off-if-unlocked.sh"
assert_log ''
rm -f "$marker"
: > "$LOCK_POLICY_LOG"
"$root/dist/libexec/dpms-off-if-unlocked.sh"
assert_log 'hyprctl:dispatch hl.dsp.dpms({ action = '"'"'off'"'"' })'

echo "lock policy routing is correct"
