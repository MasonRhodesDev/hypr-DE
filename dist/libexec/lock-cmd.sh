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
#
# THIS SCRIPT MUST NEVER FAIL OPEN. A lock request that ends with the session
# still unlocked is a security failure, not a logged inconvenience: hypridle
# moves on and the user walks away from a live desktop. (Nothing blanks an
# unlocked session any more -- hypridle only blanks while the compositor
# holds the lock -- so the screen at least stays honestly lit, but the
# session is still exposed.) So a failed locker escalates -- retry unscoped, then any
# other installed locker, then terminate the session -- and only gives up on
# locking by taking the session down with it.
set -u

# Policy lives in a root-owned file, never the environment.
# desktop-commons BAR-017 (no-unprivileged-security-bypass): a protected mode
# must not be disableable through a file, environment value, or control path
# writable by the protected principal. An env knob for the failsafe would be
# exactly that -- and ~/.config/environment.d/ makes it durable across
# reboots, so it is not merely a "they already have code execution" case.
# Loosening the failsafe is an operator decision; the session does not get one.
LOCK_CONF=/etc/hypr-de/lock.conf
FAILSAFE=terminate
FALLBACKS='swaylock -f|gtklock -d|hyprlock &'
VERIFY_TRIES=20

runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
# A durable trace that a lock attempt failed and the session was kept
# (failsafe=warn); operators and support scripts read it after the fact.
# Nothing consumes it at runtime: blanking follows the compositor lock, and
# a failed lock never holds that, so the outputs stay lit without it.
fail_marker="$runtime_dir/hypr-de-lock-failed"

log() { printf 'hypr-de lock: %s\n' "$*" >&2; }

# Locking on purpose ends the session's claim to stay awake, so release a
# held idle inhibitor -- otherwise it keeps the locked screen lit all night
# (hypridle obeys inhibitors, and hyprstate reads the logind one). The idle
# path deliberately does NOT call this: that lock fires because the user
# walked away, and an inhibitor is exactly the signal they meant the session
# to stay awake. Best effort in every direction: a missing or failing CLI
# must never affect the lock, which has already been taken by the time this
# runs.
release_idle_inhibitor() {
    command -v logind-idle-control >/dev/null 2>&1 || return 0
    timeout 2 logind-idle-control disable >/dev/null 2>&1 || \
        log "could not release the idle inhibitor; the locked screen may stay lit"
    return 0
}

# logind's LockedHint is what the session's peers (hyprstate, logind
# consumers) read, so it is the authority on "did this lock take". Never ask for
# session `self`: logind resolves it from the caller's cgroup, and hypridle
# (hence this script) runs in app.slice, not the session scope, so `self`
# fails and the hint reads as empty. Use the id the user manager exports,
# falling back to logind's `auto` (the user's display session).
locked_hint() {
    [ "$(loginctl show-session "${XDG_SESSION_ID:-auto}" -p LockedHint --value 2>/dev/null || true)" = yes ]
}

# The hint can land just after the locker returns; give it a moment before
# treating a non-zero exit as an unlocked session.
# Read operator policy, but only from a file root owns and nobody else can
# write. A config anyone else can edit is the bypass this is guarding.
load_policy() {
    [ -f "$LOCK_CONF" ] || return 0
    owner=$(stat -c '%u' "$LOCK_CONF" 2>/dev/null || echo 1)
    perms=$(stat -c '%a' "$LOCK_CONF" 2>/dev/null || echo 777)
    case "$owner:$perms" in
        0:[0-7][024][024]) ;;
        *)
            log "ignoring $LOCK_CONF: it must be owned by root and not writable by anyone else"
            return 0
            ;;
    esac
    # Parsed, not sourced: this file decides whether the screen locks.
    while IFS='=' read -r key value; do
        key=$(printf '%s' "$key" | tr -d '[:space:]')
        value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$key" in
            ''|\#*) continue ;;
            failsafe)     case "$value" in terminate|warn|none) FAILSAFE=$value ;; esac ;;
            fallbacks)    FALLBACKS=$value ;;
            verify_tries) case "$value" in ''|*[!0-9]*) ;; *) VERIFY_TRIES=$value ;; esac ;;
        esac
    done < "$LOCK_CONF"
}

locked_within() {
    tries=$VERIFY_TRIES
    while [ "$tries" -gt 0 ]; do
        locked_hint && return 0
        tries=$((tries - 1))
        if [ "$tries" -gt 0 ]; then sleep 0.1; fi
    done
    return 1
}

lock() {
    if command -v systemd-run >/dev/null 2>&1 \
        && systemd-run --user --scope --quiet --collect true >/dev/null 2>&1
    then
        systemd-run --user --scope --quiet --collect -- vigil-lock "$@"
        status=$?
        # Exit 3 is a cancelled idle lock, not a launch failure -- never retry
        # it, or a nudged mouse would lock the session anyway. Anything else
        # can be the scope failing to start rather than the locker refusing,
        # so try again without it: a locker in hypridle's cgroup beats none.
        if [ "$status" -ne 0 ] && [ "$status" -ne 3 ] && ! locked_hint; then
            log "scoped locker exited $status; retrying without the transient scope"
            vigil-lock "$@"
            status=$?
        fi
    else
        # No user manager (or transient units unavailable): still lock. A
        # locker tied to hypridle's lifetime beats no locker at all.
        vigil-lock "$@"
        status=$?
    fi
    return "$status"
}

# Emergency only, once vigil-lock is missing or broken. Each candidate is a
# command line, "|"-separated, tried in order and skipped if not installed; a
# trailing "&" means the locker holds the foreground until unlock, so it is
# backgrounded and counted as locked if it is still alive a second later.
# Restricted to lockers that return (or daemonize) as soon as the screen is
# locked, because hypridle waits for lock_cmd before it suspends -- a locker
# that blocks until unlock would hold off the suspend it was called for.
fallback_lock() {
    saved_ifs=$IFS
    IFS='|'
    for entry in $FALLBACKS; do
        IFS=$saved_ifs
        case "$entry" in
            *'&')
                # shellcheck disable=SC2086  # deliberate: entry is a command line
                set -- ${entry%&}
                [ "$#" -gt 0 ] && command -v "$1" >/dev/null 2>&1 || continue
                "$@" >/dev/null 2>&1 &
                pid=$!
                sleep 1
                if kill -0 "$pid" 2>/dev/null; then
                    log "locked with $1 (fallback)"
                    return 0
                fi
                ;;
            *)
                # shellcheck disable=SC2086  # deliberate: entry is a command line
                set -- $entry
                [ "$#" -gt 0 ] && command -v "$1" >/dev/null 2>&1 || continue
                if "$@"; then
                    log "locked with $1 (fallback)"
                    return 0
                fi
                ;;
        esac
    done
    IFS=$saved_ifs
    return 1
}

fail_closed() {
    : > "$fail_marker" 2>/dev/null || true
    case "$FAILSAFE" in
        warn|none)
            log "no locker succeeded; $LOCK_CONF sets failsafe=$FAILSAFE, so the session stays up and UNLOCKED. Outputs are kept lit so it cannot pass for a locked screen."
            ;;
        *)
            log "no locker succeeded; terminating the session rather than leaving it exposed (an operator can set failsafe=warn in $LOCK_CONF to keep it)"
            sid=${XDG_SESSION_ID:-}
            [ -n "$sid" ] || sid=$(loginctl show-session "${XDG_SESSION_ID:-auto}" -p Id --value 2>/dev/null || true)
            if [ -n "$sid" ]; then
                loginctl terminate-session "$sid"
            else
                loginctl terminate-user "$(id -u)"
            fi
            ;;
    esac
}

# 0 locked, 3 idle lock cancelled by activity, 1 fell all the way through.
lock_or_fail_closed() {
    lock "$@"
    status=$?
    [ "$status" -eq 3 ] && return 3
    if [ "$status" -eq 0 ] || locked_within; then
        rm -f "$fail_marker" 2>/dev/null || true
        return 0
    fi
    log "vigil-lock failed (exit $status) and the session is not locked"
    if fallback_lock; then
        rm -f "$fail_marker" 2>/dev/null || true
        return 0
    fi
    fail_closed
    return 1
}

load_policy

case "${1:-}" in
    --idle)
        lock_or_fail_closed --wait --warn "${VIGIL_IDLE_WARNING_SECONDS:-10}"
        status=$?
        # Exit 3 means user activity cancelled before session-lock. That is a
        # successful idle-policy outcome, not a locker failure.
        [ "$status" -eq 3 ] && exit 0
        [ "$status" -eq 0 ] || exit "$status"
        # No DPMS poke on the idle path: the outputs are lit (the unlocked
        # blank is at 240 s, this lock at 180 s) and the locked listener's
        # condition retry may have blanked them the instant the lock landed
        # -- a dpms on here would undo that and leave the locked screen lit
        # until the next input. Manual and sleep paths keep the poke.
        exit 0
        ;;
    --sleep)
        # before_sleep: never cancelable, and no DPMS poke on the way down
        # (after_sleep_cmd turns the outputs back on when we resume).
        lock_or_fail_closed --wait --no-warn || exit $?
        release_idle_inhibitor
        exit 0
        ;;
    *)
        # --no-warn pins the immediate paths even if a vigil.toml enables a
        # default warning duration: manual locks and before-sleep must never
        # be cancelable (a nudged mouse during lid-close would suspend
        # unlocked).
        lock_or_fail_closed --wait --no-warn || exit $?
        release_idle_inhibitor
        ;;
esac

exec hyprctl dispatch "hl.dsp.dpms({ action = 'on' })"
