#!/bin/bash
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

echo "== no shipped script keeps state in /tmp"
hits=$(grep -rn '"/tmp\|=/tmp\|/tmp/\$\|:-/tmp' "$root/dist" 2>/dev/null \
    | grep -v '/tmp/\.X11-unix' \
    | grep -v ':[0-9]*:[[:space:]]*#')
if [ -z "$hits" ]; then
    ok "no /tmp state paths in dist/"
else
    printf '%s\n' "$hits"
    bad "dist/ still keeps state in /tmp"
fi

echo
echo "== the recorder refuses to run without a runtime dir"
out=$(env -u XDG_RUNTIME_DIR bash -c ". '$root/dist/libexec/screen-recorder/modules/base.sh'" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "XDG_RUNTIME_DIR is unset"; then
    ok "base.sh exits when XDG_RUNTIME_DIR is unset"
else
    bad "base.sh continued without a runtime dir (rc=$rc)"
fi

echo
echo "== the recorder keeps state in the runtime dir, 0700"
export XDG_RUNTIME_DIR="$work/run"
mkdir -p "$XDG_RUNTIME_DIR"
paths=$(bash -c ". '$root/dist/libexec/screen-recorder/modules/base.sh'; printf '%s\n%s\n' \"\$STATE_FILE\" \"\$PIDFILE\"")
if printf '%s' "$paths" | grep -q "^$XDG_RUNTIME_DIR/hypr-de/"; then
    ok "state paths are under the runtime dir"
    printf '%s\n' "$paths" | sed 's/^/     /'
else
    bad "state paths are not under the runtime dir: $paths"
fi
mode=$(stat -c %a "$XDG_RUNTIME_DIR/hypr-de" 2>/dev/null)
[ "$mode" = 700 ] && ok "state dir is 0700" || bad "state dir mode is ${mode:-missing}"

echo
echo "== a recycled pid is not mistaken for the recorder"
res=$(bash -c "
    . '$root/dist/libexec/screen-recorder/modules/base.sh'
    echo \$\$ > \"\$PIDFILE\"          # a live pid: this very shell
    if is_recording; then echo RECORDING; else echo NOT; fi
")
[ "$res" = NOT ] && ok "a live non-recorder pid is not treated as a recording" \
                 || bad "is_recording accepted an unrelated live pid"

echo
echo "== notification context refuses a world-writable fallback"
for s in swaync-store-context.sh swaync-focus-sender.sh; do
    out=$(env -u XDG_RUNTIME_DIR SWAYNC_ID=1 SWAYNC_APP_NAME=x \
        bash "$root/dist/libexec/$s" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "XDG_RUNTIME_DIR is unset"; then
        ok "$s refuses to fall back to /tmp"
    else
        bad "$s ran without a runtime dir (rc=$rc)"
    fi
done
[ -e /tmp/swaync-context ] && bad "/tmp/swaync-context exists" || ok "nothing created /tmp/swaync-context"

echo
echo "== the config-reload listener locks in the runtime dir"
sub="$work/listener.sh"
sed 's|@LIBEXECDIR@|/nonexistent|g' "$root/dist/libexec/hyprland-configreload-listener.sh" > "$sub"
out=$(env -u XDG_RUNTIME_DIR bash "$sub" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "XDG_RUNTIME_DIR is unset"; then
    ok "listener refuses to lock in /tmp"
else
    bad "listener ran without a runtime dir (rc=$rc)"
fi
out=$(env -u HYPRLAND_INSTANCE_SIGNATURE bash "$sub" 2>&1)
if [ -f "$XDG_RUNTIME_DIR/hypr-de/listener.sh.lock" ] || printf '%s' "$out" | grep -q "HYPRLAND_INSTANCE_SIGNATURE"; then
    ok "listener got past locking with a runtime dir set"
else
    bad "listener did not lock as expected: $out"
fi
[ -e "/tmp/listener.sh.lock" ] && bad "/tmp lock created" || ok "no lock in /tmp"

echo
echo "== the singleton guard conforms to singleton-guard-v1"
lock="$XDG_RUNTIME_DIR/hypr-de/listener.sh.lock"
( flock -x 200; sleep 3 ) 200>"$lock" &
holder=$!
sleep 0.5
out=$(bash "$sub" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "Another instance is already running"; then
    ok "a second instance is refused while the lock is held"
else
    bad "a second instance was not refused (rc=$rc): $out"
fi
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

[ -e "$lock" ] && ok "lock file is not unlinked" || bad "lock file was unlinked (path race)"
out=$(env -u HYPRLAND_INSTANCE_SIGNATURE bash "$sub" 2>&1)
if printf '%s' "$out" | grep -q "HYPRLAND_INSTANCE_SIGNATURE"; then
    ok "a stale lock file does not lock the listener out"
else
    bad "a released lock still blocked startup: $out"
fi

echo 1 > "$lock"
out=$(env -u HYPRLAND_INSTANCE_SIGNATURE bash "$sub" 2>&1)
if printf '%s' "$out" | grep -q "HYPRLAND_INSTANCE_SIGNATURE"; then
    ok "a planted pid in the lock file is ignored"
else
    bad "a planted pid blocked the listener: $out"
fi

echo
[ "$fail" -eq 0 ] && { echo "runtime state paths are correct"; exit 0; }
exit 1
