#!/bin/sh
set -u

LOCK_CONF=/etc/hypr-de/lock.conf
FAILSAFE=terminate
FALLBACKS='swaylock -f|gtklock -d|hyprlock &'
VERIFY_TRIES=20
JOURNAL_SOCKET=/run/systemd/journal/stdout

runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
fail_marker="$runtime_dir/hypr-de-lock-failed"

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
    while [ "$tries" -gt 0 ]; do
        locked_hint && return 0
        tries=$((tries - 1))
        if [ "$tries" -gt 0 ]; then sleep 0.1; fi
    done
    return 1
}

lock() {
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
        systemd-run --user --scope --quiet --collect -- "$@"
        status=$?
        wrapped=1
    else
        "$@"
        status=$?
    fi
    if [ "$wrapped" = 1 ] && [ "$status" -ne 0 ] && [ "$status" -ne 3 ] && ! locked_hint; then
        [ "$1" = systemd-cat ] && shift 3
        log "locker exited $status; retrying it bare, outside the transient scope and the journal"
        "$@"
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
                    systemd-cat -t "$1" "$@" &
                else
                    "$@" >/dev/null 2>&1 &
                fi
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
                if { journal_ok && systemd-cat -t "$1" "$@"; } || "$@"; then
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
            timeout 5 notify-send -u critical -a hypr-de "Screen NOT locked" \
                "No screen locker could start. This session is unlocked." >/dev/null 2>&1 || true
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

lock_or_fail_closed() {
    lock "$@"
    status=$?
    [ "$status" -eq 3 ] && return 3
    if [ "$status" -eq 0 ] || locked_within || compositor_locked; then
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

if compositor_locked; then
    log "the session is already locked; not starting another locker"
    exit 0
fi

case "${1:-}" in
    --idle)
        lock_or_fail_closed --wait --warn "${VIGIL_IDLE_WARNING_SECONDS:-10}"
        status=$?
        [ "$status" -eq 3 ] && exit 0
        [ "$status" -eq 0 ] || exit "$status"
        exit 0
        ;;
    --sleep)
        lock_or_fail_closed --wait --no-warn || exit $?
        release_idle_inhibitor
        exit 0
        ;;
    *)
        lock_or_fail_closed --wait --no-warn || exit $?
        release_idle_inhibitor
        ;;
esac

exec hyprctl dispatch "hl.dsp.dpms({ action = 'on' })"
