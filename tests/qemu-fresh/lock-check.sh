#!/bin/bash
[ -e /etc/hypr-de-qemu-fresh ] || { echo "$0: runs only inside the qemu-fresh VM" >&2; exit 2; }
set -uo pipefail

fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
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

echo "== the idle driver cannot be shadowed from ~/.local/bin"
execline=$(systemctl --user cat hypridle.service 2>/dev/null | grep -E '^ExecStart=.' | tail -1)
if printf '%s' "$execline" | grep -qE 'command -v|which '; then
    bad "hypridle.service resolves its binary through \$PATH: $execline"
else
    ok "hypridle.service names absolute paths"
fi

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/hypridle" <<'STUB'
#!/bin/sh
# Stands in for a hostile shadow: looks alive, enforces no idle policy at all.
exec sleep infinity
STUB
chmod +x "$HOME/.local/bin/hypridle"
systemctl --user restart hypridle.service 2>/dev/null
sleep 2
hpid=$(systemctl --user show -p MainPID --value hypridle.service 2>/dev/null)
hexe=$(readlink -f "/proc/${hpid:-0}/exe" 2>/dev/null)
case "$hexe" in
    "$HOME"/*)
        bad "hypridle resolved to '$hexe' -- the ~/.local/bin shadow won"
        ;;
    /usr/bin/hypridle|/usr/local/bin/hypridle)
        ok "still running $hexe with the shadow in place"
        ;;
    *)
        bad "hypridle resolved to '${hexe:-<none>}', which is neither the packaged nor the local build"
        ;;
esac
rm -f "$HOME/.local/bin/hypridle"
systemctl --user restart hypridle.service 2>/dev/null
sleep 2

echo "== lock the session the way any tool does (loginctl lock-session -> hypr-de-lock.service, and hypridle if it runs)"
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
if printf '%s' "$cg" | grep -qE 'hypridle\.service|hypr-de-lock\.service'; then
    bad "locker is inside a lock requester's cgroup (restarting it would kill the locker)"
else
    ok "locker is outside hypridle.service's and hypr-de-lock.service's cgroups"
fi

for unit in hypridle.service hypr-de-lock.service; do
    echo "== restart $unit while the session is locked"
    systemctl --user restart "$unit" 2>/dev/null
    sleep 3
    if locker_up; then
        ok "locker survived the $unit restart (session stays locked)"
    else
        bad "locker was killed by the $unit restart -- session stranded on the compositor's lock-died screen"
    fi
done

echo "== cleanup: release the lock"
pkill -u "$USER" -x vigil-lock 2>/dev/null
for _ in $(seq 1 10); do locker_up || break; sleep 1; done
locker_up && bad "could not clear the locker" || ok "locker cleared"

echo
if [ "$fail" -eq 0 ]; then echo "LOCK: PASS"; exit 0; fi
echo "LOCK: FAIL"; exit 1
