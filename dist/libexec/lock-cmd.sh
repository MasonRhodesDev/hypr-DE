#!/bin/sh
# hypridle lock_cmd. --daemonize returns 0 only after ext-session-lock is
# granted. Then force DPMS on so a lock against dark outputs still has CRTCs.
if [ "${1:-}" = "--idle" ]; then
    vigil-lock --daemonize --warn "${VIGIL_IDLE_WARNING_SECONDS:-10}"
    status=$?
    # Exit 3 means user activity cancelled before session-lock. That is a
    # successful idle-policy outcome, not a locker failure.
    [ "$status" -eq 3 ] && exit 0
    [ "$status" -eq 0 ] || exit "$status"
else
    vigil-lock --daemonize || exit $?
fi
exec hyprctl dispatch "hl.dsp.dpms({ action = 'on' })"
