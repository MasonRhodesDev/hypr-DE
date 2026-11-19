#!/bin/bash
[ -e /run/tripwire/hits ] || { [ "${HYPR_DE_SEALED-}" = build-root ] && [ ! -e /run/systemd/private ]; } || exec "$(dirname -- "$0")/run" "$0"
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixtures="$root/tests/fixtures/lock-listener"
work=$(mktemp -d)
pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

command -v dbus-daemon >/dev/null && python3 -I -c 'from gi.repository import Gio' 2>/dev/null || {
    echo "lock-listener.sh needs dbus-daemon and PyGObject (python3-gi / python-gobject)" >&2; exit 1; }

cat >"$work/bus.conf" <<CONF
<busconfig>
  <listen>unix:path=$work/bus</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*"/><allow own="*"/><allow receive_sender="*"/>
  </policy>
</busconfig>
CONF
dbus-daemon --config-file="$work/bus.conf" --nofork --nopidfile & pids+=($!)
for _ in $(seq 50); do [ -S "$work/bus" ] && break; sleep 0.1; done
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$work/bus"
export LOCKS="$work/locks"
export FAKE_LOGIND_EVENTS="$work/events"
: >"$LOCKS"
: >"$FAKE_LOGIND_EVENTS"

cat >"$work/lock-cmd.sh" <<'STUB'
#!/bin/sh
echo "lock-cmd.sh session=$XDG_SESSION_ID $*" >>"$LOCKS"
sleep "${STUB_HOLD:-0}"
STUB
chmod +x "$work/lock-cmd.sh"
sed "s|@LIBEXECDIR@|$work|g" "$root/dist/libexec/hypr-de-lock-listener" >"$work/listener"
chmod +x "$work/listener"

wait_for() {
    for _ in $(seq 50); do eval "$1" && return 0; sleep 0.1; done
    return 1
}
locks() { wc -l <"$LOCKS"; }

start_logind() {
    FAKE_LOGIND_DISPLAY=${1-7} "$fixtures/fake-logind" >"$work/logind.out" & logind=$!; pids+=("$logind")
    wait_for 'grep -q ready "$work/logind.out"' || { echo "fake logind did not start" >&2; exit 1; }
}
start_listener() {
    : >"$work/listener.err"
    env "$@" "$work/listener" 2>"$work/listener.err" & listener=$!; pids+=("$listener")
    wait_for 'grep -q "locking session" "$work/listener.err"'
}

start_logind
start_listener XDG_SESSION_ID=7 STUB_HOLD=2 || { cat "$work/listener.err"; exit 1; }

kill -USR1 "$logind"
wait_for '[ "$(locks)" = 1 ]' && ok "a logind Lock on our session runs lock-cmd.sh" || bad "no lock-cmd.sh run for a logind Lock"
[ "$(cat "$LOCKS")" = "lock-cmd.sh session=7 " ] && ok "lock-cmd.sh runs for our session id" || bad "unexpected run: $(cat "$LOCKS")"

kill -USR1 "$logind"; sleep 0.5
[ "$(locks)" = 1 ] && ok "a second Lock while the first lock is starting starts no second locker" || bad "a second Lock started another lock-cmd.sh"
sleep 2
kill -USR1 "$logind"
wait_for '[ "$(locks)" = 2 ]' && ok "a Lock after the first lock finished runs lock-cmd.sh again" || bad "a later Lock was dropped"
sleep 2.2

kill -USR2 "$logind"; sleep 0.5
[ "$(locks)" = 2 ] && ok "a Lock for another session is ignored" || bad "a Lock for another session locked this one"

"$fixtures/impostor"; sleep 0.5
[ "$(locks)" = 2 ] && ok "a Lock not sent by logind is ignored" || bad "a Lock from a non-logind sender ran lock-cmd.sh"

events() { tr '\n' ',' <"$FAKE_LOGIND_EVENTS"; }
[ "$(events)" = "inhibit sleep delay," ] && ok "the listener holds a sleep delay from the start" || bad "no sleep delay held: $(events)"
kill -HUP "$logind"
wait_for '[ "$(locks)" = 3 ]' && ok "PrepareForSleep runs lock-cmd.sh --sleep" || bad "no lock before sleep"
[ "$(tail -n1 "$LOCKS")" = "lock-cmd.sh session=7 --sleep" ] || bad "unexpected sleep lock: $(tail -n1 "$LOCKS")"
sleep 0.5
[ "$(events)" = "inhibit sleep delay," ] && ok "sleep waits while lock-cmd.sh is still locking" || bad "the delay was released before the lock finished"
wait_for '[ "$(events)" = "inhibit sleep delay,released," ]' && ok "the delay is released once lock-cmd.sh returns" || bad "the delay was never released: $(events)"
kill -WINCH "$logind"
wait_for '[ "$(events)" = "inhibit sleep delay,released,inhibit sleep delay," ]' && ok "after resume the listener takes a new delay" || bad "no new delay after resume: $(events)"

kill -USR1 "$logind"
wait_for '[ "$(locks)" = 4 ]' || bad "no lock-cmd.sh run for a logind Lock"
kill -HUP "$logind"; sleep 0.5
[ "$(locks)" = 4 ] && ok "sleep during a running lock joins it instead of starting another" || bad "sleep started a second lock-cmd.sh"
wait_for '[ "$(events)" = "inhibit sleep delay,released,inhibit sleep delay,released," ]' && ok "and releases the delay when that lock returns" || bad "the delay was not released after the joined lock: $(events)"
kill -WINCH "$logind"
wait_for '[ "$(events)" = "inhibit sleep delay,released,inhibit sleep delay,released,inhibit sleep delay," ]' || bad "no delay after the second resume: $(events)"
sleep 2

kill -HUP "$logind"
wait_for '[ "$(locks)" = 5 ]' || bad "no lock before the third sleep"
kill -WINCH "$logind"
wait_for '[ "$(events)" = "inhibit sleep delay,released,inhibit sleep delay,released,inhibit sleep delay,released,inhibit sleep delay," ]' \
    && ok "a lock that returns after resume still leaves a delay held for the next sleep" \
    || bad "a late lock left no delay held: $(events)"

kill "$listener"; wait "$listener" 2>/dev/null
start_listener -u XDG_SESSION_ID || { cat "$work/listener.err"; bad "no listener without XDG_SESSION_ID"; }
kill -USR1 "$logind"
wait_for '[ "$(locks)" = 6 ]' && ok "without XDG_SESSION_ID it follows the user's graphical session" || bad "no lock without XDG_SESSION_ID"
kill "$listener"; wait "$listener" 2>/dev/null

env XDG_SESSION_ID=99 "$work/listener" 2>"$work/listener.err" & listener=$!; pids+=("$listener")
if wait_for '! kill -0 "$listener" 2>/dev/null'; then
    wait "$listener"; rc=$?
    [ "$rc" -ne 0 ] && ok "an unknown session makes the listener fail, so systemd restarts it" || bad "an unknown session exited 0"
else
    bad "the listener kept running with no session to watch"
fi

kill "$logind"; wait "$logind" 2>/dev/null
start_logind ''
env -u XDG_SESSION_ID "$work/listener" 2>"$work/listener.err" & listener=$!; pids+=("$listener")
if wait_for '! kill -0 "$listener" 2>/dev/null'; then
    wait "$listener"; rc=$?
    [ "$rc" -ne 0 ] && ok "a user with no graphical session makes the listener fail" || bad "no graphical session exited 0"
else
    bad "the listener kept running with no graphical session"
fi

unit="$root/dist/systemd/user/hypr-de-lock.service"
grep -qx 'ExecStart=@LIBEXECDIR@/hypr-de-lock-listener' "$unit" && ok "the unit runs the listener" || bad "the unit does not run the listener"
grep -qx 'KillMode=process' "$unit" && ok "restarting the unit leaves a bare locker running" || bad "a unit restart would kill a bare locker that holds the lock"
grep -qx 'Wants=hypr-de-lock.service' "$root/dist/systemd/user/graphical-session.target.d/hypr-de-lock.conf" \
    && ok "every graphical session pulls the listener in, upgraded installs included" \
    || bad "nothing starts the listener on an install that was never re-preset"

exit "$fail"
