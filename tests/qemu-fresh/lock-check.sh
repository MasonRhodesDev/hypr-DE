#!/bin/bash
# Does the screen locker survive its launcher?
#
# Every lock path goes through hypridle's lock_cmd, so without care the locker
# ends up inside hypridle.service's cgroup. That unit is KillMode=control-group,
# so restarting hypridle -- a config change, a crash, an upgrade -- kills the
# locker while the session is still locked. The compositor then shows "the
# lockscreen app died" and the only way back in is a TTY.
#
# Red/green: this fails on a build that launches the locker inline, passes on
# one that runs it in its own transient scope.
set -uo pipefail

fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
eval "$(systemctl --user show-environment 2>/dev/null \
    | grep -E '^(HYPRLAND_INSTANCE_SIGNATURE|WAYLAND_DISPLAY)=' | sed 's/^/export /')"

locker_up() { pgrep -u "$USER" -x vigil-lock >/dev/null 2>&1; }

echo "== preconditions"
pgrep -u "$USER" -x Hyprland >/dev/null || { bad "no live Hyprland session"; echo "LOCK: FAIL"; exit 1; }
ok "Hyprland session is live"
if locker_up; then
    echo "   a locker was already running; clearing it first"
    pkill -u "$USER" -x vigil-lock 2>/dev/null
    for _ in $(seq 1 10); do locker_up || break; sleep 1; done
fi

echo "== lock the session the way a user does (loginctl -> hypridle lock_cmd)"
# Must name the GRAPHICAL session: this script runs over ssh, and a bare
# loginctl lock-session would lock the ssh session instead -- hypridle is
# bound to the seat session and would never see it.
gsid=""
for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
    [ -n "$(loginctl show-session "$s" -p Seat --value 2>/dev/null)" ] || continue
    gsid="$s"; break
done
if [ -n "$gsid" ]; then
    ok "graphical session is $gsid (seat $(loginctl show-session "$gsid" -p Seat --value 2>/dev/null))"
else
    bad "could not find a seat session to lock"; echo "LOCK: FAIL"; exit 1
fi
loginctl lock-session "$gsid" 2>/dev/null || true
for _ in $(seq 1 20); do locker_up && break; sleep 1; done
if locker_up; then
    ok "locker is running after loginctl lock-session"
else
    bad "no locker appeared after lock-session"
    echo "LOCK: FAIL"; exit 1
fi

echo "== which cgroup did the locker land in?"
lpid=$(pgrep -u "$USER" -x vigil-lock | head -1)
cg=$(cat "/proc/$lpid/cgroup" 2>/dev/null | head -1)
echo "   $cg"
if printf '%s' "$cg" | grep -q 'hypridle.service'; then
    bad "locker is inside hypridle.service's cgroup (a hypridle restart will kill it)"
else
    ok "locker is outside hypridle.service's cgroup"
fi

echo "== restart hypridle while the session is locked"
systemctl --user restart hypridle.service 2>/dev/null
sleep 3
if locker_up; then
    ok "locker survived the hypridle restart (session stays locked)"
else
    bad "locker was killed by the hypridle restart -- session stranded on the compositor's lock-died screen"
fi

echo "== cleanup: release the lock"
pkill -u "$USER" -x vigil-lock 2>/dev/null
for _ in $(seq 1 10); do locker_up || break; sleep 1; done
locker_up && bad "could not clear the locker" || ok "locker cleared"

echo
if [ "$fail" -eq 0 ]; then echo "LOCK: PASS"; exit 0; fi
echo "LOCK: FAIL"; exit 1
