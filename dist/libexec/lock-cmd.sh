#!/bin/sh
# hypridle lock_cmd. --wait returns 0 only after ext-session-lock is
# granted. Then force DPMS on so a lock against dark outputs still has CRTCs.
if [ "${1:-}" = "--idle" ]; then
    vigil-lock --wait --warn "${VIGIL_IDLE_WARNING_SECONDS:-10}"
    status=$?
    # Exit 3 means user activity cancelled before session-lock. That is a
    # successful idle-policy outcome, not a locker failure.
    [ "$status" -eq 3 ] && exit 0
    [ "$status" -eq 0 ] || exit "$status"
else
    # --no-warn pins the immediate paths even if a vigil.toml enables a
    # default warning duration: manual locks and before-sleep must never
    # be cancelable (a nudged mouse during lid-close would suspend
    # unlocked).
    vigil-lock --wait --no-warn || exit $?
fi
exec hyprctl dispatch "hl.dsp.dpms({ action = 'on' })"
