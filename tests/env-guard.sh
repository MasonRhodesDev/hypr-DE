#!/bin/bash
[ -e /run/tripwire/hits ] || { [ "${HYPR_DE_SEALED-}" = build-root ] && [ ! -e /run/systemd/private ]; } || exec "$(dirname -- "$0")/run" "$0"
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }
check() {
    if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$4 (got '$1')"; fi
}

guard="$root/dist/libexec/wayland-env-guard"
work=$(mktemp -d) || exit 2
server=
trap '[ -n "$server" ] && kill "$server" 2>/dev/null; wait; rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/run"

python3 -c '
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(8)
time.sleep(120)
' "$work/run/wayland-1" &
server=$!
n=0
while [ ! -S "$work/run/wayland-1" ] && [ "$n" -lt 200 ]; do sleep 0.01; n=$(( n + 1 )); done

cat >"$work/bin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >>"$CASE/calls"
case "$*" in
    "--user show-environment") cat "$CASE/env" ;;
    "--user is-failed --quiet "*) exit 1 ;;
esac
EOF
cat >"$work/bin/dbus-update-activation-environment" <<'EOF'
#!/bin/sh
echo "dbus-update-activation-environment $*" >>"$CASE/calls"
[ ! -e "$CASE/export-fails" ]
EOF
cat >"$work/bin/hyprctl" <<EOF
#!/bin/sh
echo "hyprctl \$*" >>"\$CASE/calls"
[ "\$*" = "instances -j" ] || exit 1
printf '[{"instance": "sig", "wl_socket": "wayland-1", "pid": $server, "time": 1}]\n'
EOF
chmod +x "$work/bin"/*

# run <case> <manager env line>...: runs the guard against a manager
# environment and keeps its output, exit status and every call it made.
run() {
    local c="$work/$1"
    shift
    mkdir -p "$c"
    printf '%s\n' "$@" >"$c/env"
    : >"$c/calls"
    env -i PATH="$work/bin:/usr/bin:/bin" HOME="$work" XDG_RUNTIME_DIR="$work/run" CASE="$c" \
        bash "$guard" >"$c/out" 2>&1
    echo $? >"$c/rc"
}
writes() { grep -v -e '^systemctl --user show-environment$' -e '^systemctl --user is-failed ' -e '^hyprctl ' "$work/$1/calls"; }

echo "== a stale WAYLAND_DISPLAY is repointed in one export"
run stale WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=Hyprland
check "$(cat "$work/stale/rc")" 0 "the guard exits 0" "the guard failed on a stale socket"
grep -q "^wayland-env-guard: repointed WAYLAND_DISPLAY 'wayland-0' -> 'wayland-1'$" "$work/stale/out"
check $? 0 "it reports the repoint" "the guard did not report the repoint"
check "$(writes stale | head -n1)" \
    "dbus-update-activation-environment --systemd WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=sig" \
    "its first write is one dbus-update-activation-environment --systemd call with both variables" \
    "the guard does not export both variables in one call, D-Bus first"
check "$(writes stale | grep -c 'WAYLAND_DISPLAY\|HYPRLAND_INSTANCE_SIGNATURE')" 1 \
    "no other call sets either variable" "the guard sets the variables in more than one call"
check "$(writes stale | grep -c -e 'set-environment' -e 'import-environment')" 0 \
    "it never writes the systemd manager alone" "the guard writes the systemd manager before D-Bus activation"
order=$(writes stale | grep -n -e '^dbus-update-activation-environment --systemd WAYLAND_DISPLAY=' \
    -e '^systemctl --user restart xdg-desktop-portal-hyprland.service$' | cut -d: -f2 | cut -c1-4 | paste -sd' ' -)
check "${order}" "dbus syst" "the portal restarts after the export" "the portal restarted before the export"

echo
echo "== a failed export fails the guard and touches nothing else"
mkdir -p "$work/broken"
: >"$work/broken/export-fails"
run broken XDG_CURRENT_DESKTOP=Hyprland
check "$(cat "$work/broken/rc")" 1 "the guard exits 1" "the guard ignored a failed export"
grep -q 'repointed' "$work/broken/out"
check $? 1 "it does not claim a repoint" "the guard reported a repoint it did not make"
check "$(writes broken | grep -vc '^dbus-update-activation-environment --systemd WAYLAND_DISPLAY=')" 0 \
    "it restarts no portal" "the guard restarted the portal after a failed export"

echo
echo "== a live WAYLAND_DISPLAY is left alone"
run live WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=sig XDG_CURRENT_DESKTOP=Hyprland
check "$(cat "$work/live/rc"):$(writes live | wc -l)" "0:0" "the guard exits 0 and writes nothing" \
    "the guard changed a healthy session"

exit "$fail"
