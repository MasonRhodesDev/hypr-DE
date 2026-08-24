#!/bin/sh
# hypridle lock_cmd. --wait returns 0 only after ext-session-lock is
# granted. Then force DPMS on so a lock against dark outputs still has CRTCs.
#
# Every lock path funnels through here (SUPER+L is loginctl lock-session,
# which logind turns into hypridle's lock_cmd), so the locker would otherwise
# live in hypridle.service's cgroup. That unit is KillMode=control-group, so
# stopping or restarting hypridle -- a config change, a crash, a package
# upgrade -- kills the screen locker while the session is still locked, and
# the compositor is left showing "the lockscreen app died" with no way in
# except a TTY. vigil-lock's own setsid() leaves the TTY session but not the
# cgroup, so it cannot prevent this on its own.
#
# Run the locker in its own transient scope instead. systemd-run --scope
# moves the caller into a fresh unit and runs there, so the detached locker
# child inherits that scope, not hypridle's; the scope outlives this script
# for as long as the locker runs. Blocking semantics are unchanged, which
# matters because hypridle waits for lock_cmd before suspending.
lock() {
    if command -v systemd-run >/dev/null 2>&1 \
        && systemd-run --user --scope --quiet --collect true >/dev/null 2>&1
    then
        systemd-run --user --scope --quiet --collect -- vigil-lock "$@"
    else
        # No user manager (or transient units unavailable): still lock. A
        # locker tied to hypridle's lifetime beats no locker at all.
        vigil-lock "$@"
    fi
}

case "${1:-}" in
    --idle)
        lock --wait --warn "${VIGIL_IDLE_WARNING_SECONDS:-10}"
        status=$?
        # Exit 3 means user activity cancelled before session-lock. That is a
        # successful idle-policy outcome, not a locker failure.
        [ "$status" -eq 3 ] && exit 0
        [ "$status" -eq 0 ] || exit "$status"
        ;;
    --sleep)
        # before_sleep: never cancelable, and no DPMS poke on the way down
        # (after_sleep_cmd turns the outputs back on when we resume).
        lock --wait --no-warn || exit $?
        exit 0
        ;;
    *)
        # --no-warn pins the immediate paths even if a vigil.toml enables a
        # default warning duration: manual locks and before-sleep must never
        # be cancelable (a nudged mouse during lid-close would suspend
        # unlocked).
        lock --wait --no-warn || exit $?
        ;;
esac

exec hyprctl dispatch "hl.dsp.dpms({ action = 'on' })"
