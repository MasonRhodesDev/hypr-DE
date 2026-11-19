#!/bin/bash
[ -e /run/tripwire/hits ] || { [ "${HYPR_DE_SEALED-}" = build-root ] && [ ! -e /run/systemd/private ]; } || exec "$(dirname -- "$0")/run" "$0"
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

mkdir -p "$work/with" "$work/without" "$work/sys" "$work/libexec"
printf '#!/bin/sh\necho "lock-cmd.sh $*" >>"$LOG"\n' >"$work/libexec/lock-cmd.sh"
chmod +x "$work/libexec/lock-cmd.sh"
sed "s|@LIBEXECDIR@|$work/libexec|g" "$root/dist/libexec/power-menu.sh" >"$work/power-menu.sh"
ln -s "$(command -v cat)" "$work/sys/cat"
for d in with without; do
    printf '#!/bin/sh\ncat >/dev/null; printf "%%s\\n" "$PICK"\n' >"$work/$d/fuzzel"
    printf '#!/bin/sh\necho "hyprshutdown $*" >>"$LOG"\n' >"$work/$d/hyprshutdown"
done
printf '#!/bin/sh\necho "desktop-boot-exit $*" >>"$LOG"\n' >"$work/with/desktop-boot-exit"
chmod +x "$work"/with/* "$work"/without/*

run() {
    : >"$work/log"
    LOG="$work/log" PICK="$2" PATH="$work/$1:$work/sys" "$BASH" "$work/power-menu.sh"
    cat "$work/log"
}

[ "$(run with Reboot)" = "desktop-boot-exit -p systemctl reboot" ] && ok "reboot uses desktop-boot-exit" || bad "reboot with desktop-boot-exit"
[ "$(run with Logout)" = "desktop-boot-exit " ] && ok "logout uses desktop-boot-exit" || bad "logout with desktop-boot-exit"
[ "$(run without Shutdown)" = "hyprshutdown -p systemctl poweroff -i" ] && ok "shutdown falls back to hyprshutdown" || bad "shutdown fallback"
[ "$(run without Lock)" = "lock-cmd.sh " ] && ok "the menu's Lock runs lock-cmd.sh itself" || bad "the menu's Lock does not reach lock-cmd.sh"

bind=$(sed -n 's/^hl\.bind(mainMod \.\. " + L", hl\.dsp\.exec_cmd("\([^"]*\)").*/\1/p' "$root/dist/hypr/main.lua")
: >"$work/log"
if [ -n "$bind" ]; then
    LOG="$work/log" PATH="$work/sys" /bin/sh -c "$(printf '%s' "$bind" | sed "s|@LIBEXECDIR@|$work/libexec|g")"
fi
[ "$(cat "$work/log")" = "lock-cmd.sh " ] && ok "Super+L runs lock-cmd.sh itself" || bad "Super+L does not reach lock-cmd.sh: '$bind'"

if grep -rn 'lock-session' "$root/dist/hypr" "$root/dist/libexec" "$root/dist/bin"; then
    bad "a lock path still goes through loginctl lock-session, which nothing answers without a listener"
else
    ok "no shipped lock path depends on a logind Lock listener"
fi

exit "$fail"
