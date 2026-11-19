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
together=$(grep -w WAYLAND_DISPLAY <<<"${exports}" | grep -w HYPRLAND_INSTANCE_SIGNATURE | grep -w XDG_CURRENT_DESKTOP |
    grep -w XDG_SESSION_TYPE | grep -w XDG_SESSION_ID | grep -cw XDG_SESSION_DESKTOP)
check "$(( together > 0 ))" 1 "one export carries every session variable uwsm hands on" \
    "main.lua exports the session's variables in separate calls, so with no settle one can land after uwsm stops waiting"

echo
echo "== the session declares itself ready right after that export"
cmd=$(sed -nE 's/^\s*hl\.exec_cmd\("(dbus-update-activation-environment --systemd [^"]*)"\)$/\1/p' "$root/dist/hypr/main.lua")
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
printf '#!/bin/sh\necho "export $*" >>"$LOG"\nexit "$EXPORT_RC"\n' >"$tmp/bin/dbus-update-activation-environment"
printf '#!/bin/sh\necho "notify $*" >>"$LOG"\n' >"$tmp/bin/systemd-notify"
chmod +x "$tmp/bin"/*
hook() {
    : >"$tmp/log"
    env -i PATH="$tmp/bin:/usr/bin:/bin" LOG="$tmp/log" EXPORT_RC="$1" sh -c "${cmd}"
    cut -d' ' -f1-2 "$tmp/log" | paste -sd' ' -
}
check "$(hook 0)" "export --systemd notify READY=1" "the hook exports, then tells uwsm the session is ready" \
    "the hook must export before it declares the session ready"
check "$(grep -c 'systemd-notify READY=1 NOTIFYACCESS=exec' <<<"${cmd}")" 1 \
    "the hook closes the notify socket to other processes as uwsm finalize does" \
    "the hook must send NOTIFYACCESS=exec with READY=1"
check "$(hook 1)" "export --systemd" "a failed export declares nothing" \
    "the hook declares the session ready even when the export failed"

echo
echo "== waitenv's 0.5 s poll is skipped only for a stock hypr-DE Hyprland session"
nline=$(grep -E '^export HYPRLAND_NO_SD_NOTIFY=' "$envh")
check "$(grep -c . <<<"${nline}")" 1 "env-hyprland sets HYPRLAND_NO_SD_NOTIFY once" \
    "env-hyprland must set HYPRLAND_NO_SD_NOTIFY exactly once"
nreport="printf %s \"\${HYPRLAND_NO_SD_NOTIFY}\""
notify=$(env -i sh -c "${nline}; ${nreport}")
case "${notify}" in ''|0) on=0 ;; *) on=1 ;; esac
check "${on}" 1 "Hyprland reads env-hyprland's value as on, so it does not declare itself ready" \
    "env-hyprland's HYPRLAND_NO_SD_NOTIFY is empty or 0, which Hyprland reads as off"
check "$(env -i HYPRLAND_NO_SD_NOTIFY=0 sh -c "${nline}; ${nreport}")" 0 "a HYPRLAND_NO_SD_NOTIFY the user set wins" \
    "env-hyprland overrides the user's HYPRLAND_NO_SD_NOTIFY"
settle=$(env -i sh -c "${lines}; ${report}")
mapfile -t conds < <(grep -E '^Condition' "$root/dist/systemd/user/wayland-session-waitenv.service.d/hypr-de.conf")
waitenv() {
    if env -i PATH=/usr/bin:/bin "$@" systemd-analyze condition "${conds[@]}" >/dev/null 2>&1; then
        echo runs
    else
        echo skipped
    fi
}
stock=(HYPRLAND_NO_SD_NOTIFY="${notify}" UWSM_WAIT_VARNAMES=HYPRLAND_INSTANCE_SIGNATURE UWSM_WAIT_VARNAMES_SETTLETIME="${settle}")
check "$(waitenv "${stock[@]}")" skipped "a stock Hyprland session skips waitenv" \
    "the drop-in leaves waitenv's poll on a stock hypr-DE Hyprland login"
check "$(waitenv)" runs "another compositor keeps waitenv" "the drop-in skips waitenv for a session it does not own"
check "$(waitenv "${stock[@]}" HYPRLAND_NO_SD_NOTIFY=0)" runs "Hyprland's own ready keeps waitenv" \
    "the drop-in skips waitenv while Hyprland declares itself ready before the export"
check "$(waitenv "${stock[@]}" HYPRLAND_NO_SD_NOTIFY=yes)" runs "any other HYPRLAND_NO_SD_NOTIFY keeps waitenv" \
    "the drop-in matches a HYPRLAND_NO_SD_NOTIFY other than env-hyprland's"
check "$(waitenv "${stock[@]}" UWSM_WAIT_VARNAMES="HYPRLAND_INSTANCE_SIGNATURE MY_VAR")" runs \
    "a variable the user adds to the wait list keeps waitenv" \
    "the drop-in skips waitenv although the user waits for a variable main.lua does not export"
check "$(waitenv "${stock[@]}" UWSM_WAIT_VARNAMES_SETTLETIME=0.2)" runs "a settle the user sets keeps waitenv" \
    "the drop-in skips waitenv although the user asked for a settle"

exit "$fail"
