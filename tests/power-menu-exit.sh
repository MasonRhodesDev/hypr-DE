#!/bin/bash
[ -n "${HYPR_DE_SEALED-}" ] || exec "$(dirname -- "$0")/run" "$0"
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

mkdir -p "$work/with" "$work/without" "$work/sys"
ln -s "$(command -v cat)" "$work/sys/cat"
for d in with without; do
    printf '#!/bin/sh\ncat >/dev/null; printf "%%s\\n" "$PICK"\n' >"$work/$d/fuzzel"
    printf '#!/bin/sh\necho "hyprshutdown $*" >>"$LOG"\n' >"$work/$d/hyprshutdown"
done
printf '#!/bin/sh\necho "desktop-boot-exit $*" >>"$LOG"\n' >"$work/with/desktop-boot-exit"
chmod +x "$work"/with/* "$work"/without/*

run() {
    : >"$work/log"
    LOG="$work/log" PICK="$2" PATH="$work/$1:$work/sys" "$BASH" "$root/dist/libexec/power-menu.sh"
    cat "$work/log"
}

[ "$(run with Reboot)" = "desktop-boot-exit -p systemctl reboot" ] && ok "reboot uses desktop-boot-exit" || bad "reboot with desktop-boot-exit"
[ "$(run with Logout)" = "desktop-boot-exit " ] && ok "logout uses desktop-boot-exit" || bad "logout with desktop-boot-exit"
[ "$(run without Shutdown)" = "hyprshutdown -p systemctl poweroff -i" ] && ok "shutdown falls back to hyprshutdown" || bad "shutdown fallback"

exit "$fail"
