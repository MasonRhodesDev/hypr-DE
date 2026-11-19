#!/bin/sh
# Every locker, wrapper and probe below resolves from root-owned directories, so nothing in the
# session's environment can choose what claims a crashed lock screen.
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
set -u

LOCK_CONF=/etc/hypr-de/lock.conf
FAILSAFE=terminate
FALLBACKS='swaylock -f|gtklock -d|hyprlock &'
VERIFY_TRIES=20
JOURNAL_SOCKET=/run/systemd/journal/stdout
LOCKERS='vigil-lock swaylock gtklock hyprlock waylock'
LOCK_TIMEOUT=10
FALLBACK_WAIT=30
RESPAWN_MAX=3
RESPAWN_WINDOW=30
WATCH=1
WATCH_INTERVAL=1
COMPOSITOR_TRIES=3

runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
fail_marker="$runtime_dir/hypr-de-lock-failed"
fallback_lock_file="$runtime_dir/hypr-de-lock.lock"
respawn_log="$runtime_dir/hypr-de-lock-respawns"
watch_lock_file="$runtime_dir/hypr-de-lock-watch.lock"
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

# Returns 0 when the compositor answers locked, 1 when it answers unlocked, and 2 when it gives no
# answer, which no caller may read as unlocked: a slow compositor is likeliest just as a locker dies.
compositor_locked() {
    asks=$COMPOSITOR_TRIES
    while :; do
        case $(timeout 2 hyprctl locked 2>/dev/null) in
            true) return 0 ;;
            false) return 1 ;;
        esac
        asks=$((asks - 1))
        [ "$asks" -gt 0 ] || break
        sleep 1
    done
    log "hyprctl locked gave no answer in $COMPOSITOR_TRIES tries"
    return 2
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

# pgrep lists zombies, and a zombie's environ is unreadable, so without this a dead locker that
# nothing reaped yet reads as a live one that cannot be probed.
zombie() {
    case $(sed -n 's/^State:[[:space:]]*\([A-Z]\).*/\1/p' "/proc/$1/status" 2>/dev/null) in
        Z|X) return 0 ;;
    esac
    return 1
}

# Prints each live locker of this user on this Wayland display, so a lock held by another session's
# locker never counts. Only a clean "no such process" means dead: the compositor is locked either way,
# so a probe that cannot tell prints "?" rather than send a healthy lock to the failsafe or a respawn.
live_lockers() {
    pids=$(timeout 2 pgrep -u "$(id -u)" -x "$(locker_names)" 2>/dev/null)
    case $? in
        0) ;;
        1) return 0 ;;
        *) log "cannot list screen lockers; assuming one is alive"; echo '?'; return 0 ;;
    esac
    for pid in $pids; do
        zombie "$pid" && continue
        if [ -z "${WAYLAND_DISPLAY:-}" ]; then
            echo "$pid"
            continue
        fi
        if ! environ=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null); then
            [ -d "/proc/$pid" ] && echo "$pid"
            continue
        fi
        printf '%s\n' "$environ" | grep -qxF "WAYLAND_DISPLAY=$WAYLAND_DISPLAY" && echo "$pid"
    done
    return 0
}

locker_alive() {
    [ -n "$(live_lockers)" ]
}

# Hyprland keeps a session locked after its locker dies, so a locked compositor alone proves nothing.
# In a run that began on that crashed screen, a locker that was just denied can still be alive, so only
# a locker's own success counts there.
lock_held() {
    [ "$crashed_at_entry" = 0 ] && locker_alive && compositor_locked
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
        timeout -k 2 "$bound" systemd-run --user --scope --quiet --collect -- "$@" 8>&- 9>&-
        status=$?
        wrapped=1
    else
        timeout -k 2 "$bound" "$@" 8>&- 9>&-
        status=$?
    fi
    [ "$status" -eq 124 ] && log "vigil-lock did not confirm the lock within ${bound}s"
    if [ "$wrapped" = 1 ] && [ "$status" -ne 0 ] && [ "$status" -ne 3 ] && ! locked_hint; then
        [ "$1" = systemd-cat ] && shift 3
        log "locker exited $status; retrying it bare, outside the transient scope and the journal"
        timeout -k 2 "$bound" "$@" 8>&- 9>&-
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
                    systemd-cat -t "$1" "$@" 8>&- 9>&- &
                else
                    "$@" >/dev/null 2>&1 8>&- 9>&- &
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
                if { journal_ok && systemd-cat -t "$1" "$@" 8>&- 9>&-; } || "$@" 8>&- 9>&-; then
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

# A failed redirection on a special builtin such as ":" ends a POSIX shell, so every probe that
# may fail to open its file runs in a subshell.
fail_closed() {
    ( : > "$fail_marker" ) 2>/dev/null || log "cannot write $fail_marker"
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

# Only one run at a time may fall back or respawn: a second fallback locker is refused while the first
# holds the lock, and that refusal must not reach the failsafe. vigil-lock serialises itself, so this
# lock covers only the fallbacks, the respawn and the failsafe, and a Super+L never waits behind an
# idle warning.
serialised() {
    if command -v flock >/dev/null 2>&1 && ( : >> "$fallback_lock_file" ) 2>/dev/null; then
        {
            flock -w "$FALLBACK_WAIT" 9 || \
                log "another lock attempt held $fallback_lock_file for ${FALLBACK_WAIT}s; going ahead anyway"
            "$@"
        } 9>> "$fallback_lock_file"
    else
        log "cannot take $fallback_lock_file; going ahead without serialising"
        "$@"
    fi
}

restore_off() {
    case $(timeout 2 hyprctl getoption misc:allow_session_lock_restore 2>/dev/null | sed -n 1p) in
        'int: 0'|'bool: false'|'bool: 0') return 0 ;;
    esac
    return 1
}

# Counts every respawn, failed or not, across runs, so a locker that keeps crashing reaches the
# failsafe instead of looping.
claim_respawn() {
    now=$(date +%s)
    kept=
    if [ -f "$respawn_log" ]; then
        while read -r at; do
            case $at in ''|*[!0-9]*) continue ;; esac
            [ "$at" -gt $((now - RESPAWN_WINDOW)) ] && kept="$kept$at
"
        done < "$respawn_log"
    fi
    attempt=$(( $(printf '%s' "$kept" | grep -c .) + 1 ))
    [ "$attempt" -le "$RESPAWN_MAX" ] || return 1
    printf '%s%s\n' "$kept" "$now" > "$respawn_log" 2>/dev/null || \
        log "cannot record the respawn in $respawn_log"
    return 0
}

# With misc:allow_session_lock_restore on, Hyprland hands a crashed lock screen to the next locker.
# It also hands a healthy one to a newcomer, so this respawns only once no locker is left, and only
# the pinned vigil-lock, then the root-configured fallbacks, may claim it.
# The respawn never opens a grace window: lock.grace_secs lets any input unlock, and a crash must not
# hand that to whoever is at the keyboard.
# Returns 0 when a locker holds the lock, 1 after the failsafe, 2 when the compositor is not locked.
recover_crashed_lock() {
    if lock_held; then
        log "another lock attempt restored the lock meanwhile"
        return 0
    fi
    compositor_locked
    case $? in
        0) log "the compositor is locked but no locker is alive: the lock screen crashed" ;;
        1) return 2 ;;
        *) log "no locker is alive and the compositor gives no answer; recovering as if the lock screen crashed" ;;
    esac
    crashed_at_entry=1
    if restore_off; then
        log "misc:allow_session_lock_restore is off in the Hyprland config, so no locker can take over the crashed lock screen"
        fail_closed
        return 1
    fi
    deadline=$(( $(date +%s) + RESPAWN_WINDOW ))
    while claim_respawn; do
        left=$(( deadline - $(date +%s) ))
        [ "$left" -ge 1 ] || break
        [ "$left" -lt "$LOCK_TIMEOUT" ] || left=$LOCK_TIMEOUT
        log "respawning vigil-lock to take over the crashed lock screen (attempt $attempt of $RESPAWN_MAX in ${RESPAWN_WINDOW}s)"
        if lock "$left" --wait --no-warn --grace 0; then
            log "vigil-lock took over the crashed lock screen"
            rm -f "$fail_marker" 2>/dev/null || true
            return 0
        fi
        log "the respawned vigil-lock exited $status without taking the lock"
    done
    log "vigil-lock could not take over the crashed lock screen within $RESPAWN_MAX attempts in ${RESPAWN_WINDOW}s"
    if fallback_lock; then
        rm -f "$fail_marker" 2>/dev/null || true
        return 0
    fi
    fail_closed
    return 1
}

# Outlives the run that started it, in its own scope like the locker, so a crashed lock screen
# recovers at once instead of waiting for a lock request nobody at the keyboard can make.
start_watcher() {
    [ "$WATCH" = 1 ] || return 0
    set -- "$0" --watch
    if command -v systemd-run >/dev/null 2>&1 \
        && systemd-run --user --scope --quiet --collect true >/dev/null 2>&1
    then
        set -- systemd-run --user --scope --quiet --collect -- "$@"
    else
        log "systemd-run cannot start a user scope; starting the lock watcher as a plain process in this caller's cgroup"
    fi
    setsid "$@" </dev/null >/dev/null 2>&1 8>&- 9>&- &
}

watch_lockers() {
    if ! ( : >> "$watch_lock_file" ) 2>/dev/null; then
        log "cannot open $watch_lock_file; no lock watcher runs, so a crashed lock screen recovers only on the next lock request"
        exit 0
    fi
    exec 8>> "$watch_lock_file"
    flock -n 8 || exit 0
    while :; do
        for pid in $(live_lockers); do
            if [ "$pid" = '?' ]; then
                sleep "$WATCH_INTERVAL"
                continue
            fi
            while [ -d "/proc/$pid" ] && ! zombie "$pid"; do sleep "$WATCH_INTERVAL"; done
        done
        locker_alive && continue
        crashed_at_entry=0
        serialised recover_crashed_lock
        [ "$?" -eq 0 ] || exit 0
    done
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
    serialised fallback_or_fail_closed || return 1
    rm -f "$fail_marker" 2>/dev/null || true
    return 0
}

load_policy

case "${1:-}" in
    --watch)
        watch_lockers
        ;;
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
        set -- --idle $((LOCK_TIMEOUT + warn)) --wait --warn "$warn"
        ;;
    --sleep)
        set -- --sleep "$LOCK_TIMEOUT" --wait --no-warn
        ;;
    *)
        set -- '' "$LOCK_TIMEOUT" --wait --no-warn
        ;;
esac
mode=$1
shift

compositor_locked
compositor=$?
status=2
if [ "$compositor" -ne 1 ]; then
    if locker_alive; then
        log "a locker is alive; not starting another"
        exit 0
    fi
    serialised recover_crashed_lock
    status=$?
fi
if [ "$status" -eq 2 ]; then
    lock_or_fail_closed "$@"
    status=$?
    [ "$status" -eq 3 ] && [ "$mode" = --idle ] && exit 0
fi
[ "$status" -eq 0 ] || exit "$status"

start_watcher
[ "$mode" = --idle ] && exit 0
release_idle_inhibitor
[ "$mode" = --sleep ] && exit 0
exec hyprctl dispatch "hl.dsp.dpms({ action = 'on' })"
