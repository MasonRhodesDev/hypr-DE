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

echo "== live session"
if pgrep -u "$USER" -x Hyprland >/dev/null; then
    ok "Hyprland is running (upgrade happened under a live session)"
else
    bad "no live Hyprland -- this test proves nothing without one"
    echo "UPGRADE: FAIL"; exit 1
fi

echo "== no config error left by the upgrade"
errs=$(hyprctl configerrors 2>&1)
if [ -z "$errs" ] || printf '%s' "$errs" | grep -qi 'no errors'; then
    ok "hyprctl configerrors is clean after the upgrade"
else
    printf '%s\n' "$errs"
    bad "config errors latched by the upgrade (the banner users see)"
fi

echo "== recovery mechanism (deterministic red/green)"
helper=/usr/lib/hypr-de/hypr-de-reload-sessions
[ -x "$helper" ] || helper=/usr/libexec/hypr-de/hypr-de-reload-sessions
if [ -x "$helper" ]; then
    sudo mv /etc/xdg/hypr/hyprland.lua /tmp/hyprland.lua.uptest
    hyprctl reload >/dev/null 2>&1
    induced=$(hyprctl configerrors 2>&1)
    sudo mv /tmp/hyprland.lua.uptest /etc/xdg/hypr/hyprland.lua
    if [ -n "$induced" ] && ! printf '%s' "$induced" | grep -qi 'no errors'; then
        ok "induced the latched banner: $(printf '%s' "$induced" | head -1)"
        still=$(hyprctl configerrors 2>&1)
        if [ -n "$still" ] && ! printf '%s' "$still" | grep -qi 'no errors'; then
            ok "error persists after the file returns (restore alone is not enough)"
        else
            ok "error self-cleared on restore (nothing for the helper to do)"
        fi
        sudo "$helper" >/dev/null 2>&1
        after=$(hyprctl configerrors 2>&1)
        if [ -z "$after" ] || printf '%s' "$after" | grep -qi 'no errors'; then
            ok "reload helper cleared the latched config error"
        else
            printf '%s\n' "$after"
            bad "reload helper did NOT clear the latched error"
        fi
    else
        bad "could not induce a config error -- recovery path unverified"
        sudo "$helper" >/dev/null 2>&1 || true
    fi
else
    bad "reload helper not installed; cannot verify recovery"
fi

echo "== packaged config survived the transaction"
if [ -r /etc/xdg/hypr/hyprland.lua ]; then
    ok "/etc/xdg/hypr/hyprland.lua readable"
else
    bad "/etc/xdg/hypr/hyprland.lua missing after upgrade"
fi

echo "== the reload hook actually fired"
if command -v pacman >/dev/null; then
    if sudo grep -q '95-hypr-de-reload.hook' /var/log/pacman.log 2>/dev/null; then
        ok "pacman ran 95-hypr-de-reload.hook"
        if sudo grep -q 'reloaded .* live Hyprland session' /var/log/pacman.log 2>/dev/null; then
            ok "hook reloaded a live session"
        else
            bad "hook ran but reloaded no session (helper found none?)"
        fi
    else
        bad "pacman never ran the reload hook"
    fi
else
    if [ -x /usr/libexec/hypr-de/hypr-de-reload-sessions ]; then
        ok "reload helper installed (rpm %posttrans path)"
    else
        bad "reload helper missing"
    fi
fi

echo "== session survived the upgrade"
for p in waybar swaync; do
    if pgrep -u "$USER" -x "$p" >/dev/null; then ok "$p still running"; else bad "$p died across the upgrade"; fi
done
uf=$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[ -z "$uf" ] && ok "no failed user units" || bad "failed user units: $uf"

echo
if [ "$fail" -eq 0 ]; then echo "UPGRADE: PASS"; exit 0; fi
echo "UPGRADE: FAIL"; exit 1
