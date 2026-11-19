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
export NOTES="$work/notes"
: >"$LOCKS"
: >"$FAKE_LOGIND_EVENTS"
: >"$NOTES"
mkdir -p "$work/bin" "$work/runtime/hypr/none"
cat >"$work/bin/notify-send" <<'STUB'
#!/bin/sh
echo "$*" >>"$NOTES"
STUB
chmod +x "$work/bin/notify-send"
export PATH="$work/bin:$PATH"
export XDG_RUNTIME_DIR="$work/runtime"
export HYPRLAND_INSTANCE_SIGNATURE=none

cat >"$work/lock-cmd.sh" <<'STUB'
#!/bin/sh
echo "lock-cmd.sh session=$XDG_SESSION_ID $*" >>"$LOCKS"
sleep "${STUB_HOLD:-0}"
STUB
chmod +x "$work/lock-cmd.sh"
sed -e "s|@LIBEXECDIR@|$work|g" -e "s|^LOCK_DEADLINE_SECONDS = .*|LOCK_DEADLINE_SECONDS = 2|" \
    "$root/dist/libexec/hypr-de-lock-listener" >"$work/listener"
chmod +x "$work/listener"

wait_for() {
    for _ in $(seq 50); do eval "$1" && return 0; sleep 0.1; done
    return 1
}
locks() { wc -l <"$LOCKS"; }
events() { tr '\n' ',' <"$FAKE_LOGIND_EVENTS"; }

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

start_listener XDG_SESSION_ID=9 || { cat "$work/listener.err"; bad "no listener when XDG_SESSION_ID names a text session"; }
kill -USR1 "$logind"
wait_for '[ "$(locks)" = 7 ]' && [ "$(tail -n1 "$LOCKS")" = "lock-cmd.sh session=7 " ] \
    && ok "an XDG_SESSION_ID naming a non-wayland session is passed over" \
    || bad "the listener bound to a tty session: $(tail -n1 "$LOCKS")"
kill "$listener"; wait "$listener" 2>/dev/null

: >"$NOTES"
start_listener XDG_SESSION_ID=7 STUB_HOLD=30 || { cat "$work/listener.err"; exit 1; }
kill -USR1 "$logind"
wait_for '[ "$(locks)" = 8 ]' || bad "no lock-cmd.sh run for a logind Lock"
released() { grep -c released "$FAKE_LOGIND_EVENTS"; }
before=$(released)
kill -HUP "$logind"
wait_for '[ "$(released)" = $((before + 1)) ]' \
    && ok "a lock-cmd.sh that never returns still releases the sleep delay at the deadline" \
    || bad "a stuck lock-cmd.sh kept the sleep delay: $(events)"
wait_for 'grep -q . "$NOTES"' && ok "a stuck lock-cmd.sh posts a visible failure" || bad "no notification for a stuck lock-cmd.sh"
kill -WINCH "$logind"
kill -USR1 "$logind"
wait_for '[ "$(locks)" = 9 ]' && ok "a Lock after a stuck lock-cmd.sh runs lock-cmd.sh again" || bad "a stuck lock-cmd.sh swallowed later Lock requests"
kill "$listener"; wait "$listener" 2>/dev/null

env XDG_SESSION_ID=7 XDG_SEAT=seat0 sleep 300 & hyprland=$!; pids+=("$hyprland")
mkdir -p "$work/runtime/hypr/live"
printf '%s\nwayland-1\n' "$hyprland" >"$work/runtime/hypr/live/hyprland.lock"
kill "$logind"; wait "$logind" 2>/dev/null
FAKE_LOGIND_SESSION_8="wayland yes seat0" start_logind 8
start_listener XDG_SESSION_ID=8 HYPRLAND_INSTANCE_SIGNATURE=live || { cat "$work/listener.err"; bad "no listener with a stale XDG_SESSION_ID"; }
kill -USR2 "$logind"; sleep 0.5
kill -USR1 "$logind"
wait_for '[ "$(locks)" = 10 ]' && [ "$(tail -n1 "$LOCKS")" = "lock-cmd.sh session=7 " ] \
    && ok "a stale XDG_SESSION_ID loses to the session Hyprland itself runs in" \
    || bad "the listener followed a stale XDG_SESSION_ID: $(tail -n2 "$LOCKS" | tr '\n' ' ')"
kill "$listener"; wait "$listener" 2>/dev/null
kill "$logind"; wait "$logind" 2>/dev/null

env sleep 300 & leader=$!; pids+=("$leader")
printf '%s\nwayland-1\n' "$leader" >"$work/runtime/hypr/live/hyprland.lock"
FAKE_LOGIND_PID_SESSIONS="$leader:7" FAKE_LOGIND_SESSION_8="wayland yes seat0" start_logind 8
start_listener XDG_SESSION_ID=8 HYPRLAND_INSTANCE_SIGNATURE=live || { cat "$work/listener.err"; bad "no listener when logind knows Hyprland's pid"; }
kill -USR1 "$logind"
wait_for '[ "$(locks)" = 11 ]' && [ "$(tail -n1 "$LOCKS")" = "lock-cmd.sh session=7 " ] \
    && ok "logind's own session for Hyprland's pid comes first" \
    || bad "GetSessionByPID on Hyprland was not preferred: $(tail -n1 "$LOCKS")"
kill "$listener"; wait "$listener" 2>/dev/null
kill "$logind"; wait "$logind" 2>/dev/null

: >"$work/display"
FAKE_LOGIND_DISPLAY_FILE="$work/display" start_logind
env XDG_SESSION_ID=99 "$work/listener" 2>"$work/listener.err" & listener=$!; pids+=("$listener")
sleep 1
if kill -0 "$listener" 2>/dev/null; then
    ok "with no session to bind yet the listener keeps running"
    grep -q "waiting" "$work/listener.err" && ok "and says what it is waiting for" || bad "the wait is silent: $(cat "$work/listener.err")"
else
    bad "the listener exited with no session to bind; systemd's start limit would give up on it"
fi
echo 7 >"$work/display"
wait_for 'grep -q "locking session 7" "$work/listener.err"' && ok "the listener binds once the session appears" || bad "the listener never bound: $(cat "$work/listener.err")"
kill -USR1 "$logind"
wait_for '[ "$(locks)" = 12 ]' && ok "and then answers Lock" || bad "no lock after a late bind"
kill "$listener"; wait "$listener" 2>/dev/null

env -u HYPRLAND_INSTANCE_SIGNATURE "$work/listener" 2>"$work/listener.err" & listener=$!; pids+=("$listener")
if wait_for '! kill -0 "$listener" 2>/dev/null'; then
    wait "$listener"; rc=$?
    [ "$rc" = 0 ] && grep -q "not a Hyprland session" "$work/listener.err" \
        && ok "outside Hyprland the listener says so and exits 0, so systemd does not restart it" \
        || bad "outside Hyprland: exit $rc, $(cat "$work/listener.err")"
else
    bad "the listener kept running outside Hyprland"
fi

unit="$root/dist/systemd/user/hypr-de-lock.service"
grep -qx 'ExecStart=@LIBEXECDIR@/hypr-de-lock-listener' "$unit" && ok "the unit runs the listener" || bad "the unit does not run the listener"
grep -qx 'KillMode=process' "$unit" && ok "restarting the unit leaves a bare locker running" || bad "a unit restart would kill a bare locker that holds the lock"
[ "$(sed -n '/^\[Unit\]/,/^\[/{/^StartLimitIntervalSec=/p}' "$unit")" = StartLimitIntervalSec=0 ] \
    && ok "the start limit never gives up on the listener" || bad "systemd's default start limit can leave Lock unanswered"
grep -qx 'Restart=on-failure' "$unit" && ok "a clean exit outside Hyprland is not restarted" || bad "the unit restarts a clean exit"
grep -q '^ConditionEnvironment=' "$unit" && bad "a ConditionEnvironment skip is silent" || ok "no silent start condition"
python3 -I -c '
import sys, tomllib
group = tomllib.load(open(sys.argv[1], "rb"))["lock-idle"]
sys.exit(not ("python3-gobject" in group["fedora"] and "python-gobject" in group["arch"]))
' "$root/deps.toml" && ok "the lock-idle group declares PyGObject" || bad "the lock-idle group does not declare PyGObject"
grep -qx 'Wants=hypr-de-lock.service' "$root/dist/systemd/user/graphical-session.target.d/hypr-de-lock.conf" \
    && ok "every graphical session pulls the listener in, upgraded installs included" \
    || bad "nothing starts the listener on an install that was never re-preset"

exit "$fail"
