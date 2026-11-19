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

echo "== uwsm's settle pause stays off the Hyprland login"
envh="$root/dist/uwsm/env-hyprland"
lines=$(grep -E '^export UWSM_WAIT_VARNAMES_SETTLETIME=' "$envh")
count=$(grep -c . <<<"${lines}")
check "${count}" 1 "env-hyprland sets UWSM_WAIT_VARNAMES_SETTLETIME once" \
    "env-hyprland must set UWSM_WAIT_VARNAMES_SETTLETIME exactly once"
report="printf %s \"\${UWSM_WAIT_VARNAMES_SETTLETIME}\""
fresh=$(env -i sh -c "${lines}; ${report}")
check "${fresh}" 0 "a Hyprland session waits 0 s after its variables appear" \
    "env-hyprland leaves uwsm's settle above 0"
preset=$(env -i UWSM_WAIT_VARNAMES_SETTLETIME=0.5 sh -c "${lines}; ${report}")
check "${preset}" 0.5 "a settle already in the environment wins" \
    "env-hyprland overrides a settle the user already set"
common=$(grep -c UWSM_WAIT_VARNAMES_SETTLETIME "$root/dist/uwsm/env")
check "${common}" 0 "other compositors keep uwsm's settle" \
    "the common uwsm env sets the settle for every compositor, not only Hyprland"

echo
echo "== the session's variables arrive with the ones uwsm waits for"
exports=$(grep -E '^\s*hl\.exec_cmd\("dbus-update-activation-environment --systemd ' "$root/dist/hypr/main.lua")
together=$(grep -w WAYLAND_DISPLAY <<<"${exports}" | grep -w HYPRLAND_INSTANCE_SIGNATURE | grep -cw XDG_CURRENT_DESKTOP)
check "$(( together > 0 ))" 1 "one export carries WAYLAND_DISPLAY, HYPRLAND_INSTANCE_SIGNATURE and XDG_CURRENT_DESKTOP" \
    "main.lua exports the session's variables in separate calls, so with no settle one can land after uwsm stops waiting"

exit "$fail"
