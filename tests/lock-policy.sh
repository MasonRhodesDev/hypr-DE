#!/bin/sh
[ -e /run/tripwire/hits ] || { [ "${HYPR_DE_SEALED-}" = build-root ] && [ ! -e /run/systemd/private ]; } || exec "$(dirname -- "$0")/run" "$0"
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixtures="$root/tests/fixtures/lock-policy"
src="$root/dist/libexec/lock-cmd.sh"
work=$(mktemp -d)
export LOCK_POLICY_HOLDERS="$work/holders"
: > "$LOCK_POLICY_HOLDERS"
gone() {
    case $(sed -n 's/^State:[[:space:]]*\([A-Z]\).*/\1/p' "/proc/$1/status" 2>/dev/null) in
        ''|Z|X) return 0 ;;
    esac
    return 1
}
stop_holders() {
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$LOCK_POLICY_HOLDERS"
    while read -r pid; do
        i=0
        while ! gone "$pid" && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    done < "$LOCK_POLICY_HOLDERS"
    : > "$LOCK_POLICY_HOLDERS"
}
trap 'stop_holders; rm -rf "$work"' EXIT
display=wayland-test
start_holder() {
    WAYLAND_DISPLAY=$1 "$fixtures/vigil-lock" --hold </dev/null >/dev/null 2>&1 &
    echo $! >> "$LOCK_POLICY_HOLDERS"
}

export LOCK_POLICY_LOG="$work/log"
export LOCK_POLICY_JOURNAL="$work/journal"
export PATH="$fixtures:$PATH"
export XDG_RUNTIME_DIR="$work"
marker="$work/hypr-de-lock-failed"
lock_conf="$work/lock.conf"
journal_socket="$work/journal.sock"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$journal_socket"

mk_lock() {
    sed -e "s|^LOCK_CONF=.*|LOCK_CONF=$lock_conf|" \
        -e "s|^JOURNAL_SOCKET=.*|JOURNAL_SOCKET=${3:-$journal_socket}|" \
        -e "s|^FAILSAFE=.*|FAILSAFE=${2:-terminate}|" \
        -e "s|^FALLBACKS=.*|FALLBACKS='${1:-}'|" \
        -e "s|^VERIFY_TRIES=.*|VERIFY_TRIES=1|" \
        -e "s|^LOCK_TIMEOUT=.*|LOCK_TIMEOUT=3|" \
        -e "s|^FALLBACK_WAIT=.*|FALLBACK_WAIT=12|" \
        "$src" > "$work/lock-cmd.sh"
    chmod +x "$work/lock-cmd.sh"
}

mk_libexec() {
    grep -q '^PATH=/usr/local/bin:/usr/bin:/bin; export PATH$' "$root/dist/libexec/$1" || {
        echo "$1 must pin PATH to root-owned directories" >&2; exit 1; }
    sed -e "s|^PATH=.*|PATH=$fixtures:/usr/bin:/bin; export PATH|" \
        "$root/dist/libexec/$1" > "$work/$1"
    chmod +x "$work/$1"
}
status=0
run_lock() {
    status=0
    env -u XDG_SESSION_ID WAYLAND_DISPLAY="$display" "$work/lock-cmd.sh" "$@" 2>>"$work/stderr" || status=$?
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

mk_lock
: > "$LOCK_POLICY_LOG"
run_lock
assert_log 'vigil-lock:--wait --no-warn
logind-idle-control:disable
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'

: > "$LOCK_POLICY_LOG"
VIGIL_IDLE_WARNING_SECONDS=7 run_lock --idle
assert_log 'vigil-lock:--wait --warn 7'

: > "$LOCK_POLICY_LOG"
LOCK_POLICY_VIGIL_STATUS=3 run_lock --idle
assert_status 0
assert_log 'vigil-lock:--wait --warn 10'
assert_marker no

: > "$LOCK_POLICY_LOG"
LOCK_POLICY_SCOPE_STATUS=1 run_lock
assert_status 0
assert_log 'systemd-run:scope-failed
vigil-lock:--wait --no-warn
logind-idle-control:disable
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'
assert_marker no

mk_lock 'swaylock -f'
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_VIGIL_STATUS=1 \
    PATH="$root/tests/fixtures/lock-policy-fallback:$PATH" run_lock
assert_status 0
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
swaylock:-f
logind-idle-control:disable
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'
assert_marker no

mk_lock
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_VIGIL_STATUS=1 run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'
assert_marker yes

mk_lock '' warn
: > "$LOCK_POLICY_LOG"
rm -f "$marker"
LOCK_POLICY_VIGIL_STATUS=1 run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
notify-send:-u critical -a hypr-de Screen NOT locked No screen locker could start. This session is unlocked.'
assert_marker yes

: > "$LOCK_POLICY_LOG"
run_lock
assert_status 0
assert_marker no

mk_lock
: > "$LOCK_POLICY_LOG"
rm -f "$marker" "$lock_conf"
HYPR_DE_LOCK_FAILSAFE=warn HYPR_DE_LOCK_FALLBACKS='true' \
    LOCK_POLICY_VIGIL_STATUS=1 run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'

: > "$LOCK_POLICY_LOG"
: > "$work/stderr"
rm -f "$marker"
printf 'failsafe=warn\n' > "$lock_conf"
if [ "$(id -u)" -eq 0 ]; then
    chown 65534:65534 "$lock_conf" 2>/dev/null \
        || chown nobody:nobody "$lock_conf" 2>/dev/null \
        || chown nobody "$lock_conf" 2>/dev/null || true
fi
if [ "$(stat -c '%u' "$lock_conf")" != 0 ]; then
    LOCK_POLICY_VIGIL_STATUS=1 run_lock
    assert_status 1
    assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'
    grep -q "must be owned by root" "$work/stderr" || {
        echo "expected a warning that the policy file was ignored" >&2; exit 1
    }
else
    echo "skip: cannot create a non-root-owned policy file in this environment"
fi

if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
    printf '# operator policy\nfailsafe = warn\n' > "$lock_conf"
    if [ "$(id -u)" -eq 0 ]; then chown 0:0 "$lock_conf"; else sudo -n chown 0:0 "$lock_conf"; fi
    chmod 644 "$lock_conf" 2>/dev/null || sudo -n chmod 644 "$lock_conf"
    : > "$LOCK_POLICY_LOG"
    : > "$work/stderr"
    rm -f "$marker"
    LOCK_POLICY_VIGIL_STATUS=1 run_lock
    cp "$work/stderr" "$work/stderr.tail"
    assert_status 1
    assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
notify-send:-u critical -a hypr-de Screen NOT locked No screen locker could start. This session is unlocked.'
    grep -q "must be owned by root" "$work/stderr.tail" 2>/dev/null && {
        echo "root-owned policy file was still rejected" >&2; exit 1; }
    echo "operator policy honoured when root owns it (spaced syntax parsed)"
fi
rm -f "$lock_conf" 2>/dev/null || sudo -n rm -f "$lock_conf"

: > "$LOCK_POLICY_LOG"
run_lock
assert_log 'vigil-lock:--wait --no-warn
logind-idle-control:disable
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'

: > "$LOCK_POLICY_LOG"
run_lock --sleep
assert_log 'vigil-lock:--wait --no-warn
logind-idle-control:disable'

: > "$LOCK_POLICY_LOG"
run_lock --idle
assert_log 'vigil-lock:--wait --warn 10'

: > "$LOCK_POLICY_LOG"
LOCK_POLICY_INHIBIT_STATUS=1 run_lock
assert_status 0

started=$(date +%s)
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_INHIBIT_HANG=1 run_lock --sleep
assert_status 0
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 15 ] || {
    echo "a wedged toggle daemon delayed the lock by ${elapsed}s; the release must be bounded" >&2
    exit 1; }

mk_lock
start_holder "$display"
for mode in '' --idle --sleep; do
    : > "$LOCK_POLICY_LOG"
    LOCK_POLICY_COMPOSITOR_LOCKED=true run_lock $mode
    assert_status 0
    assert_log ''
done
stop_holders
echo "a request while a live locker holds the lock starts no second locker"

WAYLAND_DISPLAY=$display python3 -I -c '
import ctypes, time
libc = ctypes.CDLL(None)
libc.prctl(15, b"vigil-lock", 0, 0, 0)
libc.prctl(4, 0, 0, 0, 0)
time.sleep(60)
' &
echo $! >> "$LOCK_POLICY_HOLDERS"
sleep 0.3
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_LOCKED=true run_lock
assert_status 0
assert_log ''
stop_holders
echo "a live locker whose environment cannot be read still counts as alive"

rm -f "$marker"
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_LOCKED=true LOCK_POLICY_VIGIL_STATUS=1 run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'
assert_marker yes
echo "a locked compositor with no live locker (the lock screen crashed) reaches the failsafe"

start_holder wayland-other
rm -f "$marker"
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_LOCKED=true LOCK_POLICY_VIGIL_STATUS=1 run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'
stop_holders
echo "a locker on another display does not count as this session's"

python3 -I -c '
import ctypes, os, sys, time
pid = os.fork()
if pid == 0:
    ctypes.CDLL(None).prctl(15, b"vigil-lock", 0, 0, 0)
    os._exit(0)
print(pid, flush=True)
time.sleep(60)
' > "$work/zombie" &
echo $! >> "$LOCK_POLICY_HOLDERS"
i=0
until [ -s "$work/zombie" ] && gone "$(cat "$work/zombie")" || [ "$i" -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
cat "$work/zombie" >> "$LOCK_POLICY_HOLDERS"
rm -f "$marker"
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_LOCKED=true LOCK_POLICY_VIGIL_STATUS=1 run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'
stop_holders
echo "a dead locker nothing has reaped yet is not a live locker"

: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_LOCKED=true LOCK_POLICY_VIGIL_STATUS=1 LOCK_POLICY_VIGIL_HOLDS=1 run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'
stop_holders
echo "a denied locker still alive in a crashed-lock run does not count as the lock"

mk_lock 'swaylock \&'
rm -f "$marker"
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_LOCKED=true LOCK_POLICY_VIGIL_STATUS=1 LOCK_POLICY_SWAYLOCK_HOLD=3 \
    PATH="$root/tests/fixtures/lock-policy-fallback:$PATH" run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
swaylock:
loginctl:terminate-session 7'
echo "on a crashed lock screen a backgrounded fallback that is merely alive is not a lock"

mk_lock '' warn
rm -f "$marker"
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_LOCKED=true LOCK_POLICY_VIGIL_STATUS=1 run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
notify-send:-u critical -a hypr-de Lock screen crashed The session is still locked but nothing can unlock it. Switch to a TTY (Ctrl+Alt+F2) to recover.'
echo "failsafe=warn names the crashed lock screen and the way back"

mk_lock 'swaylock -f'
lockfile="$work/compositor-locked"
rm -rf "$lockfile" "$marker"
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_LOCK_FILE=$lockfile LOCK_POLICY_VIGIL_LOCKS=1 LOCK_POLICY_VIGIL_HOLDS=1 LOCK_POLICY_VIGIL_STATUS=2 \
    PATH="$root/tests/fixtures/lock-policy-fallback:$PATH" run_lock
assert_status 0
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
logind-idle-control:disable
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'
assert_marker no
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_LOCK_FILE=$lockfile run_lock
assert_status 0
assert_log ''
stop_holders
rm -rf "$lockfile"
echo "a locker that exits non-zero after the compositor locked is not a failure: no fallback, no failsafe"

mk_lock 'swaylock -f'
rm -rf "$lockfile" "$lockfile.claim" "$marker" "$work/barrier"
: > "$LOCK_POLICY_LOG"
race() {
    LOCK_POLICY_LOCK_FILE=$lockfile LOCK_POLICY_VIGIL_STATUS=1 LOCK_POLICY_SWAYLOCK_BARRIER="$work/barrier" \
        LOCK_POLICY_SWAYLOCK_LAG=0.5 \
        PATH="$root/tests/fixtures/lock-policy-fallback:$PATH" run_lock
    echo "$status" > "$work/race.$1"
}
started=$(date +%s)
race a & race_a=$!
race b & race_b=$!
wait "$race_a" "$race_b"
elapsed=$(( $(date +%s) - started ))
if grep -q '^loginctl:' "$LOCK_POLICY_LOG"; then
    echo "two concurrent lock runs ended a locked session:" >&2; cat "$LOCK_POLICY_LOG" >&2; exit 1
fi
[ "$(grep -c '^swaylock:locked$' "$LOCK_POLICY_LOG")" = 1 ] || {
    echo "expected exactly one fallback lock:" >&2; cat "$LOCK_POLICY_LOG" >&2; exit 1; }
[ "$(cat "$work/race.a") $(cat "$work/race.b")" = "0 0" ] || {
    echo "both racing runs must succeed, got $(cat "$work/race.a") $(cat "$work/race.b")" >&2; exit 1; }
[ "$elapsed" -lt 10 ] || {
    echo "the second run waited ${elapsed}s: a locker kept the fallback lock file held" >&2; exit 1; }
stop_holders
rm -rf "$lockfile" "$lockfile.claim"
echo "two concurrent runs whose vigil-lock fails fall back once and terminate nothing"

mk_lock
rm -f "$lockfile" "$marker"
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_LOCK_FILE=$lockfile LOCK_POLICY_VIGIL_LOCKS=1 LOCK_POLICY_VIGIL_STATUS=2 run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'
rm -f "$lockfile"
echo "a locker that locked and then died is not a lock: the failsafe runs"

mk_lock
rm -f "$marker"
: > "$LOCK_POLICY_LOG"
started=$(date +%s)
LOCK_POLICY_VIGIL_HANG=1 run_lock
elapsed=$(( $(date +%s) - started ))
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'
[ "$elapsed" -lt 15 ] || {
    echo "a vigil-lock that never confirmed held lock-cmd.sh for ${elapsed}s; the wait must be bounded" >&2
    exit 1; }
echo "a vigil-lock that never confirms is bounded and reaches the failsafe"

: > "$LOCK_POLICY_LOG"
VIGIL_IDLE_WARNING_SECONDS='1 0' run_lock --idle
assert_status 0
assert_log 'vigil-lock:--wait --warn 10'
echo "a malformed idle warning falls back to the default instead of aborting the lock"

mk_lock
: > "$LOCK_POLICY_LOG"
: > "$LOCK_POLICY_JOURNAL"
run_lock
assert_status 0
grep -qx 'vigil-lock: exec vigil-lock --wait --no-warn' "$LOCK_POLICY_JOURNAL" || {
    echo "vigil-lock was not started with its output on the journal as vigil-lock" >&2
    cat "$LOCK_POLICY_JOURNAL" >&2; exit 1; }

: > "$LOCK_POLICY_LOG"
: > "$LOCK_POLICY_JOURNAL"
LOCK_POLICY_SCOPE_STATUS=1 run_lock
assert_status 0
grep -q '^hypr-de-lock: locker exited 1; retrying it bare' "$LOCK_POLICY_JOURNAL" || {
    echo "lock-cmd.sh's own log lines did not reach the journal from a bind's /dev/null stderr" >&2
    cat "$LOCK_POLICY_JOURNAL" >&2; exit 1; }

: > "$LOCK_POLICY_LOG"
: > "$LOCK_POLICY_JOURNAL"
LOCK_POLICY_JOURNAL_STATUS=1 run_lock
assert_status 0
assert_log 'vigil-lock:--wait --no-warn
logind-idle-control:disable
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'
assert_marker no
echo "a journal wrapper that cannot start does not count as a lock failure"

mk_lock 'swaylock -f'
: > "$LOCK_POLICY_LOG"
: > "$LOCK_POLICY_JOURNAL"
LOCK_POLICY_VIGIL_STATUS=1 \
    PATH="$root/tests/fixtures/lock-policy-fallback:$PATH" run_lock
assert_status 0
grep -qx 'swaylock: exec swaylock -f' "$LOCK_POLICY_JOURNAL" || {
    echo "a fallback locker was not started with its output on the journal" >&2; exit 1; }

mk_lock 'swaylock \&'
: > "$LOCK_POLICY_LOG"
: > "$LOCK_POLICY_JOURNAL"
LOCK_POLICY_VIGIL_STATUS=1 LOCK_POLICY_SWAYLOCK_HOLD=3 \
    PATH="$root/tests/fixtures/lock-policy-fallback:$PATH" run_lock
assert_status 0
grep -qx 'swaylock: exec swaylock' "$LOCK_POLICY_JOURNAL" || {
    echo "a backgrounded fallback locker was not started with its output on the journal" >&2; exit 1; }

mk_lock '' terminate "$work/no-journal.sock"
: > "$LOCK_POLICY_LOG"
: > "$LOCK_POLICY_JOURNAL"
run_lock
assert_status 0
assert_log 'vigil-lock:--wait --no-warn
logind-idle-control:disable
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'
[ ! -s "$LOCK_POLICY_JOURNAL" ] || {
    echo "with no journal socket the locker must run directly" >&2; exit 1; }

mk_lock
: > "$LOCK_POLICY_JOURNAL"
JOURNAL_STREAM=$(stat -L -c '%d:%i' "$work/stderr") LOCK_POLICY_SCOPE_STATUS=1 run_lock
if grep -q '^hypr-de-lock:' "$LOCK_POLICY_JOURNAL"; then
    echo "stderr already on the journal: log lines must not be written twice" >&2; exit 1
fi
echo "the locker's output and lock-cmd.sh's own lines reach the journal on every launch path"

mk_libexec session-locked.sh
mk_libexec dpms-off-if-locked.sh
LOCK_POLICY_COMPOSITOR_LOCKED=true "$work/session-locked.sh" || {
    echo "session-locked.sh must pass while the compositor is locked" >&2; exit 1; }
if LOCK_POLICY_COMPOSITOR_LOCKED=false LOCK_POLICY_LOCKED_HINT=yes "$work/session-locked.sh"; then
    echo "session-locked.sh: a stale LockedHint must not authorise a blank" >&2; exit 1
fi

LOCK_POLICY_COMPOSITOR_LOCKED=true LOCK_POLICY_INHIBIT_ENABLED=1 "$work/session-locked.sh" || {
    echo "session-locked.sh: a locked screen must blank even with the toggle held" >&2; exit 1; }

mkdir -p "$work/no-toggle"
cp "$fixtures/hyprctl" "$work/no-toggle/hyprctl"
cp "$(command -v timeout)" "$work/no-toggle/timeout"

started=$(date +%s)
LOCK_POLICY_COMPOSITOR_HANG=1 "$work/session-locked.sh" && {
    echo "session-locked.sh: an unanswered compositor must not authorise a blank" >&2; exit 1; }
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_HANG=1 "$work/dpms-off-if-locked.sh"
assert_log ''
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 15 ] || {
    echo "a wedged compositor stalled the scripts for ${elapsed}s; both must bound it" >&2
    exit 1; }
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_LOCKED=true "$work/dpms-off-if-locked.sh"
assert_log 'hyprctl:dispatch hl.dsp.dpms({ action = '\''off'\'' })'
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_LOCKED=false LOCK_POLICY_LOCKED_HINT=yes "$work/dpms-off-if-locked.sh"
assert_log ''
mkdir -p "$work/planted" "$work/system"
printf '#!/bin/sh\necho true\n' > "$work/planted/hyprctl"
printf '#!/bin/sh\necho false\n' > "$work/system/hyprctl"
ln -s "$(command -v timeout)" "$work/system/timeout"
chmod +x "$work/planted/hyprctl" "$work/system/hyprctl"
sed -e "s|^PATH=/usr/local/bin:/usr/bin:/bin;|PATH=$work/system;|" \
    "$root/dist/libexec/session-locked.sh" > "$work/session-locked-pinned.sh"
grep -q "^PATH=$work/system;" "$work/session-locked-pinned.sh" || {
    echo "session-locked.sh must pin PATH to root-owned directories" >&2; exit 1; }
if PATH="$work/planted:$PATH" sh "$work/session-locked-pinned.sh" 2>/dev/null; then
    echo "session-locked.sh consulted a PATH-planted hyprctl" >&2; exit 1
fi

mk_libexec no-keep-awake.sh
"$work/no-keep-awake.sh" || {
    echo "no-keep-awake.sh: with no claims, ladder entry must be allowed" >&2; exit 1; }
if out=$(LOCK_POLICY_INHIBIT_CLIENT=chromium "$work/no-keep-awake.sh"); then
    echo "no-keep-awake.sh: a Wayland client claim must block ladder entry" >&2; exit 1
else
    [ "$out" = "wayland:chromium" ] || {
        echo "no-keep-awake.sh must name the Wayland holder, got '$out'" >&2; exit 1; }
fi
if LOCK_POLICY_INHIBIT_ENABLED=1 "$work/no-keep-awake.sh" >/dev/null; then
    echo "no-keep-awake.sh: the toggle must block ladder entry" >&2; exit 1
fi
if LOCK_POLICY_LOGIND_IDLE_BLOCK=1 "$work/no-keep-awake.sh" >/dev/null; then
    echo "no-keep-awake.sh: a logind idle block must block ladder entry" >&2; exit 1
fi
if LOCK_POLICY_GAME=steam "$work/no-keep-awake.sh" >/dev/null; then
    echo "no-keep-awake.sh: a running Steam game must block ladder entry" >&2; exit 1
fi
if LOCK_POLICY_GAME=gamescope "$work/no-keep-awake.sh" >/dev/null; then
    echo "no-keep-awake.sh: a gamescope session must block ladder entry" >&2; exit 1
fi
started=$(date +%s)
LOCK_POLICY_COMPOSITOR_HANG=1 "$work/no-keep-awake.sh" || {
    echo "no-keep-awake.sh: a wedged compositor alone must not read as a claim" >&2; exit 1; }
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 10 ] || {
    echo "no-keep-awake.sh waited ${elapsed}s on a wedged compositor" >&2; exit 1; }

conf="$root/dist/hypr/hypridle.conf"
[ "$(grep -cE '^[[:space:]]*ignore_inhibit=true$' "$conf")" = 2 ] || {
    echo "hypridle.conf: exactly the two lock-gated listeners ignore inhibitors" >&2; exit 1; }
has_line() {
    printf '%s' "$1" | grep -q "^  $(printf '%s' "$2" | sed 's/[$]/\\$/g')"
}
knob() { sed -n "s/^\$$1[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p" "$conf"; }
[ "$(knob blank_timeout)" = 30 ] || {
    echo "hypridle.conf: \$blank_timeout no longer defaults to 30" >&2; exit 1; }
block=$(awk '/^listener \{/{inb=1;b="";next} inb&&/^\}/{inb=0; if (b ~ /session-locked\.sh/) print b; next} inb{b=b $0 "\n"}' "$conf")
for want in 'timeout=$blank_timeout' 'condition_cmd=@LIBEXECDIR@/session-locked.sh' 'condition_retry=' \
            'on-timeout=@LIBEXECDIR@/dpms-off-if-locked.sh'; do
    has_line "$block" "$want" || {
        echo "hypridle.conf: the locked-screen listener lost '$want'" >&2; exit 1; }
done
if grep -F "action = 'off'" "$conf" | grep -q .; then
    echo "hypridle.conf: a raw dpms-off dispatch bypasses the lock checks" >&2; exit 1
fi
want_cmds='after_sleep_cmd=hyprctl dispatch "hl.dsp.dpms({ action = '"'"'on'"'"' })"
before_sleep_cmd=@LIBEXECDIR@/lock-cmd.sh --sleep
lock_cmd=@LIBEXECDIR@/lock-cmd.sh
on-resume=@LIBEXECDIR@/idle-suspend.sh --cancel
on-resume=hyprctl dispatch "hl.dsp.dpms({ action = '"'"'on'"'"' })"
on-timeout=@LIBEXECDIR@/dpms-off-if-locked.sh
on-timeout=@LIBEXECDIR@/idle-suspend.sh
on-timeout=@LIBEXECDIR@/lock-cmd.sh --idle'
got_cmds=$(sed -n 's/^[[:space:]]*\(on-timeout\|on-resume\|after_sleep_cmd\|before_sleep_cmd\|lock_cmd\)=/\1=/p' \
    "$conf" | LC_ALL=C sort)
[ "$got_cmds" = "$want_cmds" ] || {
    echo "hypridle.conf: the set of commands hypridle runs changed" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$want_cmds" "$got_cmds" >&2
    exit 1; }

mk_libexec idle-suspend.sh
: > "$LOCK_POLICY_LOG"
"$work/idle-suspend.sh"
assert_log 'hyprstate:suspend request'
: > "$LOCK_POLICY_LOG"
"$work/idle-suspend.sh" --cancel
assert_log 'hyprstate:suspend cancel'
: > "$LOCK_POLICY_LOG"
sed -e "s|^PATH=.*|PATH=$work/no-toggle; export PATH|" \
    "$root/dist/libexec/idle-suspend.sh" > "$work/idle-suspend-no-hyprstate.sh"
chmod +x "$work/idle-suspend-no-hyprstate.sh"
"$work/idle-suspend-no-hyprstate.sh" || {
    echo "idle-suspend.sh must exit 0 when hyprstate is absent" >&2; exit 1; }
if [ -s "$LOCK_POLICY_LOG" ]; then
    echo "idle-suspend.sh ran something with hyprstate absent" >&2; exit 1
fi
[ "$(knob lock_timeout)" = 180 ] || {
    echo "hypridle.conf: \$lock_timeout no longer defaults to 180" >&2; exit 1; }
lblock=$(awk '/^listener \{/{inb=1;b="";next} inb&&/^\}/{inb=0; if (b ~ /lock-cmd\.sh --idle/) print b; next} inb{b=b $0 "\n"}' "$conf")
for want in 'timeout=$lock_timeout' 'condition_cmd=@LIBEXECDIR@/no-keep-awake.sh' 'condition_retry='; do
    has_line "$lblock" "$want" || {
        echo "hypridle.conf: the idle-lock listener lost '$want'" >&2; exit 1; }
done
if printf '%s' "$lblock" | grep -qE '^[[:space:]]*ignore_inhibit'; then
    echo "hypridle.conf: the idle-lock listener must keep the inhibitor ledger as its second belt" >&2; exit 1
fi

[ "$(knob suspend_timeout)" = 900 ] || {
    echo "hypridle.conf: \$suspend_timeout no longer defaults to 900" >&2; exit 1; }
sblock=$(awk '/^listener \{/{inb=1;b="";next} inb&&/^\}/{inb=0; if (b ~ /idle-suspend\.sh/) print b; next} inb{b=b $0 "\n"}' "$conf")
for want in 'timeout=$suspend_timeout' 'ignore_inhibit=true' \
            'condition_cmd=@LIBEXECDIR@/session-locked.sh' 'condition_retry=' \
            'on-timeout=@LIBEXECDIR@/idle-suspend.sh' \
            'on-resume=@LIBEXECDIR@/idle-suspend.sh --cancel'; do
    has_line "$sblock" "$want" || {
        echo "hypridle.conf: the idle-suspend listener lost '$want'" >&2; exit 1; }
done

blanker() {
    : > "$LOCK_POLICY_LOG"
    LOCK_POLICY_COMPOSITOR_LOCKED=$1 LOCK_POLICY_LOCKED_HINT=$2 "$work/session-locked.sh" \
        && LOCK_POLICY_COMPOSITOR_LOCKED=$1 LOCK_POLICY_LOCKED_HINT=$2 "$work/dpms-off-if-locked.sh"
    if [ -s "$LOCK_POLICY_LOG" ]; then echo locked; else echo none; fi
    : > "$LOCK_POLICY_LOG"
}
for case in "true yes locked" "true no locked" "false no none" "false yes none"; do
    set -- $case
    got=$(blanker "$1" "$2")
    [ "$got" = "$3" ] || {
        echo "compositor_locked=$1 hint=$2: expected the $3 listener to blank, got $got" >&2
        exit 1; }
done

restarter="$root/dist/libexec/hypr-de-restart-session-units"
[ -x "$restarter" ] || {
    echo "the post-transaction unit restarter is missing or not executable" >&2; exit 1; }

rfix="$work/runfix"; mkdir -p "$rfix/1000/systemd"
rhelper="$work/restarter"
sed -e "s|/run/user/\*|$rfix/*|" -e "s|\${run#/run/user/}|\${run#$rfix/}|" \
    "$restarter" > "$rhelper"
chmod +x "$rhelper"
grep -q "$rfix" "$rhelper" || {
    echo "the restarter fixture rewrite did not take; the cases below would pass vacuously" >&2
    exit 1; }

rbin="$work/rbin2"; mkdir -p "$rbin"
cat > "$rbin/runuser" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$RESTART_OUT"
while [ $# -gt 0 ]; do
    case "$1" in --) shift; break ;; *) shift ;; esac
done
exec "$@"
STUB
cat > "$rbin/hyprctl" <<'STUB'
#!/bin/sh
# The real hyprctl refuses without a signature: prints to stdout, exits 1.
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || {
    echo "HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)"; exit 1; }
[ "${FIXTURE_HYPRCTL_BROKEN:-0}" = 1 ] && { echo "error"; exit 1; }
[ "$1" = locked ] && { printf '%s\n' "${FIXTURE_LOCKED:-false}"; exit 0; }
exit 0
STUB
cat > "$rbin/systemctl" <<'STUB'
#!/bin/sh
for a in "$@"; do case "$a" in
    show) printf '%s\n' "$([ -f "$RESTART_OUT.did" ] && echo 222 || echo 111)"; exit 0 ;;
    try-restart) : > "$RESTART_OUT.did"
        printf 'systemctl try-restart\n' >> "$RESTART_OUT"; exit 0 ;;
    is-active) [ -f "$RESTART_OUT.did" ] && [ "${FIXTURE_ACTIVE:-0}" = 0 ]; exit $? ;;
    is-failed) exit "${FIXTURE_FAILED:-1}" ;;
esac; done
exit 0
STUB
printf '#!/bin/sh\necho fixtureuser\n' > "$rbin/id"
printf '#!/bin/sh\necho 1000\n' > "$rbin/stat"
chmod +x "$rbin"/*
export RESTART_OUT="$work/restart.out"
mkdir -p "$rfix/1000/hypr/testsig"
python3 -c "
import socket
s = socket.socket(socket.AF_UNIX); s.bind('$rfix/1000/hypr/testsig/.socket.sock')
" 2>/dev/null || true

run_restarter() {
    : > "$RESTART_OUT"; rm -f "$RESTART_OUT.did"
    env "$@" PATH="$rbin:$PATH" RESTART_OUT="$RESTART_OUT" bash "$rhelper" 2>&1
}

grep -qE 'timeout( -k [0-9]+)? [0-9]+ runuser' "$restarter" || {
    echo "the restarter must bound runuser: a user-owned socket can hang systemctl for ever" >&2
    exit 1; }

out=$(run_restarter FIXTURE_LOCKED=false || true)
grep -q 'systemctl try-restart' "$RESTART_OUT" || {
    echo "an unlocked session did not get its unit restarted" >&2; exit 1; }
grep -q 'HYPRLAND_INSTANCE_SIGNATURE=testsig' "$RESTART_OUT" || {
    echo "the lock check ran without a signature; the guard could never fire" >&2; exit 1; }
printf '%s' "$out" | grep -q 'restarted 1' || {
    echo "a real restart was not reported" >&2; exit 1; }

run_restarter FIXTURE_LOCKED=true >/dev/null || true
grep -q 'systemctl try-restart' "$RESTART_OUT" && {
    echo "a locked session was restarted; that can kill the locker" >&2; exit 1; }

run_restarter FIXTURE_LOCKED=false FIXTURE_HYPRCTL_BROKEN=1 >/dev/null || true
grep -q 'systemctl try-restart' "$RESTART_OUT" && {
    echo "lock state was unreadable and it restarted anyway; that must fail closed" >&2
    exit 1; }

out=$(run_restarter FIXTURE_LOCKED=false FIXTURE_ACTIVE=1 FIXTURE_FAILED=0 || true)
printf '%s' "$out" | grep -q 'failed state' || {
    echo "a unit that died on restart was not reported as failed" >&2; exit 1; }
printf '%s' "$out" | grep -q 'restarted 1' && {
    echo "a unit that died on restart was counted as a success" >&2; exit 1; }

printf '#!/bin/sh\necho 4242\n' > "$rbin/stat"
run_restarter FIXTURE_LOCKED=false >/dev/null || true
[ -s "$RESTART_OUT" ] && {
    echo "ran as a user for a runtime dir that uid does not own" >&2; exit 1; }
printf '#!/bin/sh\necho 1000\n' > "$rbin/stat"

if ! run_restarter FIXTURE_LOCKED=true >/dev/null 2>&1; then
    echo "the restarter must never fail the transaction" >&2; exit 1
fi

grep -q 'hypr-de-restart-session-units' "$root/dist/pacman/96-hypr-de-restart-units.hook" || {
    echo "the restarter has no pacman hook of its own" >&2; exit 1; }
grep -q 'hypr-de-restart-session-units' "$root/packaging/hypr-de.spec" || {
    echo "the rpm scriptlet does not run the restarter" >&2; exit 1; }
for hook in "$root"/dist/pacman/*.hook; do
    n=$(grep -c '^Exec' "$hook" || true)
    [ "$n" = 1 ] || {
        echo "$(basename "$hook") has $n Exec lines; alpm keeps only the last" >&2; exit 1; }
done
grep -q 'hypr-de-reload-sessions' "$root/dist/pacman/95-hypr-de-reload.hook" || {
    echo "hook 95 no longer runs the config reload it exists for" >&2; exit 1; }
for hook in 95-hypr-de-reload 96-hypr-de-restart-units; do
    grep -q "$hook" "$root/packaging/PKGBUILD" || {
        echo "$hook is not installed by the PKGBUILD" >&2; exit 1; }
done

echo "lock policy routing is correct"
