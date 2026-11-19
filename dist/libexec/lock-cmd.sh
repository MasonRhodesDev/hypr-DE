#!/bin/sh
set -u

LOCK_CONF=/etc/hypr-de/lock.conf
FAILSAFE=terminate
FALLBACKS='swaylock -f|gtklock -d|hyprlock &'
VERIFY_TRIES=20
JOURNAL_SOCKET=/run/systemd/journal/stdout
LOCKERS='vigil-lock swaylock gtklock hyprlock waylock'
LOCK_TIMEOUT=10
FALLBACK_WAIT=30

runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
fail_marker="$runtime_dir/hypr-de-lock-failed"
fallback_lock_file="$runtime_dir/hypr-de-lock.lock"
crashed_at_entry=0

journal_ok() { [ -S "$JOURNAL_SOCKET" ] && command -v systemd-cat >/dev/null 2>&1; }

# Hyprland points a bind's stderr at /dev/null; a service's already reaches the journal.
log_to_journal=0
if journal_ok && [ "$(stat -L -c '%d:%i' "/proc/$$/fd/2" 2>/dev/null)" != "${JOURNAL_STREAM:-}" ]; then
    log_to_journal=1
fi

log() {
    printf 'hypr-de lock: %s\n' "$*" >&2
    [ "$log_to_journal" = 1 ] || return 0
    printf '%s\n' "$*" | systemd-cat -t hypr-de-lock -p warning >/dev/null 2>&1 || true
}

release_idle_inhibitor() {
    command -v logind-idle-control >/dev/null 2>&1 || return 0
    timeout 2 logind-idle-control disable >/dev/null 2>&1 || \
        log "could not release the idle inhibitor; the locked screen may stay lit"
    return 0
}

compositor_locked() {
    [ "$(timeout 2 hyprctl locked 2>/dev/null)" = true ]
}

locker_names() {
    names=$LOCKERS
    saved_ifs=$IFS
    IFS='|'
    for entry in $FALLBACKS; do
        IFS=$saved_ifs
        # shellcheck disable=SC2086  # deliberate: entry is a command line
        set -- ${entry%&}
        [ "$#" -gt 0 ] && names="$names ${1##*/}"
    done
    IFS=$saved_ifs
    # shellcheck disable=SC2086  # deliberate: one name per word
    printf '%s\n' $names | cut -c1-15 | sort -u | paste -sd'|'
}

# A locker of this user on this Wayland display, so a lock held by another session's locker never counts.
# Only a clean "no such process" means dead: the compositor is locked either way, so a probe that
# cannot tell must not send a healthy lock to the failsafe.
locker_alive() {
    pids=$(timeout 2 pgrep -u "$(id -u)" -x "$(locker_names)" 2>/dev/null)
    case $? in
        0) ;;
        1) return 1 ;;
        *) log "cannot list screen lockers; assuming one is alive"; return 0 ;;
    esac
    [ -n "${WAYLAND_DISPLAY:-}" ] || return 0
    for pid in $pids; do
        if ! environ=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null); then
            [ -d "/proc/$pid" ] && return 0
            continue
        fi
        printf '%s\n' "$environ" | grep -qxF "WAYLAND_DISPLAY=$WAYLAND_DISPLAY" && return 0
    done
    return 1
}

# Hyprland keeps a session locked after its locker dies, so a locked compositor alone proves nothing.
# In a run that began on that crashed screen, a locker that was just denied can still be alive, so only
# a locker's own success counts there.
lock_held() {
    [ "$crashed_at_entry" = 0 ] && compositor_locked && locker_alive
}

locked_hint() {
    [ "$(loginctl show-session "${XDG_SESSION_ID:-auto}" -p LockedHint --value 2>/dev/null || true)" = yes ]
}

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
    give_up=$(( $(date +%s) + 3 ))
    while [ "$tries" -gt 0 ] && [ "$(date +%s)" -lt "$give_up" ]; do
        lock_held && return 0
        tries=$((tries - 1))
        if [ "$tries" -gt 0 ]; then sleep 0.1; fi
    done
    return 1
}

# vigil-lock --wait returns once the lock is up; its locker daemon has its own session, so the
# timeout ends only the wait, never the lock.
lock() {
    bound=$1
    shift
    wrapped=0
    if journal_ok; then
        set -- systemd-cat -t vigil-lock vigil-lock "$@"
        wrapped=1
    else
        set -- vigil-lock "$@"
    fi
    if command -v systemd-run >/dev/null 2>&1 \
        && systemd-run --user --scope --quiet --collect true >/dev/null 2>&1
    then
        timeout -k 2 "$bound" systemd-run --user --scope --quiet --collect -- "$@"
        status=$?
        wrapped=1
    else
        timeout -k 2 "$bound" "$@"
        status=$?
    fi
    [ "$status" -eq 124 ] && log "vigil-lock did not confirm the lock within ${bound}s"
    if [ "$wrapped" = 1 ] && [ "$status" -ne 0 ] && [ "$status" -ne 3 ] && ! locked_hint; then
        [ "$1" = systemd-cat ] && shift 3
        log "locker exited $status; retrying it bare, outside the transient scope and the journal"
        timeout -k 2 "$bound" "$@"
        status=$?
    fi
    return "$status"
}

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
                if journal_ok; then
                    systemd-cat -t "$1" "$@" 9>&- &
                else
                    "$@" >/dev/null 2>&1 9>&- &
                fi
                pid=$!
                sleep 1
                if [ "$crashed_at_entry" = 1 ]; then
                    log "$1 started, but on a crashed lock screen a running locker proves nothing"
                elif kill -0 "$pid" 2>/dev/null; then
                    log "locked with $1 (fallback)"
                    return 0
                fi
                lock_held && return 0
                ;;
            *)
                # shellcheck disable=SC2086  # deliberate: entry is a command line
                set -- $entry
                [ "$#" -gt 0 ] && command -v "$1" >/dev/null 2>&1 || continue
                if { journal_ok && systemd-cat -t "$1" "$@" 9>&-; } || "$@" 9>&-; then
                    log "locked with $1 (fallback)"
                    return 0
                fi
                lock_held && return 0
                ;;
        esac
    done
    IFS=$saved_ifs
    return 1
}

fail_closed() {
    : > "$fail_marker" 2>/dev/null || true
    case "$FAILSAFE:$crashed_at_entry" in
        warn:1|none:1)
            log "the lock screen crashed and no locker could take over; $LOCK_CONF sets failsafe=$FAILSAFE, so the session stays up, locked, with nothing to unlock it"
            timeout 5 notify-send -u critical -a hypr-de "Lock screen crashed" \
                "The session is still locked but nothing can unlock it. Switch to a TTY (Ctrl+Alt+F2) to recover." >/dev/null 2>&1 || true
            ;;
        warn:*|none:*)
            log "no locker succeeded; $LOCK_CONF sets failsafe=$FAILSAFE, so the session stays up and UNLOCKED. Outputs are kept lit so it cannot pass for a locked screen."
            timeout 5 notify-send -u critical -a hypr-de "Screen NOT locked" \
                "No screen locker could start. This session is unlocked." >/dev/null 2>&1 || true
            ;;
        *)
            log "no locker succeeded; terminating the session rather than leaving it exposed or stuck (an operator can set failsafe=warn in $LOCK_CONF to keep it)"
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

fallback_or_fail_closed() {
    if lock_held; then
        log "another lock attempt locked the session meanwhile"
        return 0
    fi
    fallback_lock && return 0
    if lock_held; then
        log "another lock attempt locked the session meanwhile"
        return 0
    fi
    fail_closed
    return 1
}

# Only one run at a time may fall back: a second fallback locker is refused while the first holds the
# lock, and that refusal must not reach the failsafe. vigil-lock serialises itself, so this lock
# covers only the fallbacks and the failsafe, and a Super+L never waits behind an idle warning.
serialised_fallback() {
    if command -v flock >/dev/null 2>&1 && { : >> "$fallback_lock_file"; } 2>/dev/null; then
        {
            flock -w "$FALLBACK_WAIT" 9 || \
                log "another lock attempt held $fallback_lock_file for ${FALLBACK_WAIT}s; falling back anyway"
            fallback_or_fail_closed
        } 9>> "$fallback_lock_file"
    else
        log "cannot take $fallback_lock_file; falling back without serialising"
        fallback_or_fail_closed
    fi
}

lock_or_fail_closed() {
    lock "$@"
    status=$?
    [ "$status" -eq 3 ] && return 3
    if [ "$status" -eq 0 ] || locked_within; then
        rm -f "$fail_marker" 2>/dev/null || true
        return 0
    fi
    log "vigil-lock failed (exit $status) and the session is not locked"
    serialised_fallback || return 1
    rm -f "$fail_marker" 2>/dev/null || true
    return 0
}

load_policy

if compositor_locked; then
    if locker_alive; then
        log "the session is already locked; not starting another locker"
        exit 0
    fi
    crashed_at_entry=1
    log "the compositor is locked but no locker is alive: the lock screen crashed; trying to lock again"
fi

case "${1:-}" in
    --idle)
        warn=${VIGIL_IDLE_WARNING_SECONDS:-10}
        case "$warn" in
            ''|*[!0-9]*)
                log "ignoring VIGIL_IDLE_WARNING_SECONDS='$warn': not a whole number of seconds"
                warn=10
                ;;
        esac
        warn=${warn#"${warn%%[!0]*}"}
        [ -n "$warn" ] || warn=0
        lock_or_fail_closed $((LOCK_TIMEOUT + warn)) --wait --warn "$warn"
        status=$?
        [ "$status" -eq 3 ] && exit 0
        [ "$status" -eq 0 ] || exit "$status"
        exit 0
        ;;
    --sleep)
        lock_or_fail_closed "$LOCK_TIMEOUT" --wait --no-warn || exit $?
        release_idle_inhibitor
        exit 0
        ;;
    *)
        lock_or_fail_closed "$LOCK_TIMEOUT" --wait --no-warn || exit $?
        release_idle_inhibitor
        ;;
esac

exec hyprctl dispatch "hl.dsp.dpms({ action = 'on' })"
