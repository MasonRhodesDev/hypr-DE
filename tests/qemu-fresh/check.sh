#!/bin/bash
# Second-boot checks for a hypr-DE QEMU guest. Run on the guest (or via ssh).
# Exit 0 only when packaged login path, man pages, plugins, and units look sane.
set -euo pipefail

fail=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

pkg_at_least() {
    local pkg=$1 want=$2 have
    have=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}' | sed 's/-.*//') || {
        bad "$pkg is not installed"
        return
    }
    if [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -1)" = "$want" ]; then
        ok "$pkg $have (>= $want)"
    else
        bad "$pkg $have (need >= $want)"
    fi
}

echo "== packages"
pkg_at_least hypr-de 0.2.8
pkg_at_least vigil 0.2.8
pkg_at_least waybar-workspace-buttons 1.0.3
pkg_at_least man-db 2.0
pkg_at_least waybar 0.15
pkg_at_least greetd 0.10

echo "== files"
for f in \
    /usr/bin/man \
    /usr/bin/vigil \
    /usr/bin/hypr-de-setup \
    /usr/bin/hypr-de-help \
    /usr/share/man/man7/hypr-de.7.gz \
    /usr/share/man/man7/workspace-zones.7.gz \
    /usr/share/man/man1/hypr-de-help.1.gz \
    /usr/lib/waybar/workspace_buttons.so \
    /usr/lib/hyprland/plugins/libworkspace-zones.so \
    /etc/xdg/hypr/hyprland.lua \
    /usr/share/hypr-de/waybar/config.jsonc \
    /usr/share/vigil/slint-kit/ui/theme.slint
do
    if [ -e "$f" ]; then
        ok "$f"
    else
        bad "missing $f"
    fi
done

echo "== config"
if grep -q 'command = "/usr/bin/vigil"' /etc/greetd/config.toml 2>/dev/null; then
    ok "greetd command is vigil"
else
    bad "greetd is not pointed at /usr/bin/vigil"
fi
if grep -q 'command -v swaync-client' /usr/share/hypr-de/waybar/config.jsonc; then
    ok "waybar notifications exec-if uses command -v"
else
    bad "waybar notifications still use which (or exec-if missing)"
fi
if grep -q '/usr/lib/hyprland/plugins/libworkspace-zones.so' /usr/share/hypr-de/hypr/main.lua; then
    ok "main.lua loads packaged workspace-zones"
else
    bad "main.lua does not mention packaged workspace-zones path"
fi

echo "== man"
if MANPAGER=cat MANWIDTH=72 man hypr-de >/dev/null 2>&1; then
    ok "man hypr-de"
else
    bad "man hypr-de failed"
fi
if MANPAGER=cat MANWIDTH=72 man workspace-zones >/dev/null 2>&1; then
    ok "man workspace-zones"
else
    bad "man workspace-zones failed"
fi

echo "== greetd / vigil"
if systemctl is-active --quiet greetd; then
    ok "greetd active"
else
    bad "greetd is $(systemctl is-active greetd 2>/dev/null || echo missing)"
fi
if pgrep -u greeter -x vigil >/dev/null; then
    ok "vigil running as greeter"
else
    bad "no vigil process as greeter"
fi
if journalctl -b -u greetd --no-pager 2>/dev/null | grep -q 'embedded default theme is invalid'; then
    bad "vigil panicked on embedded theme (slint-kit include path)"
else
    ok "no vigil embedded-theme panic in greetd journal"
fi
if journalctl -b -u greetd --no-pager 2>/dev/null | grep -q 'start-limit-hit'; then
    bad "greetd hit start-limit this boot"
else
    ok "greetd did not hit start-limit"
fi

echo "== failed units"
mapfile -t sys_failed < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v '^$' || true)
if [ "${#sys_failed[@]}" -eq 0 ]; then
    ok "no failed system units"
else
    bad "failed system units: ${sys_failed[*]}"
fi
if [ -d /run/user/1000 ]; then
    mapfile -t usr_failed < <(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v '^$' || true)
    if [ "${#usr_failed[@]}" -eq 0 ]; then
        ok "no failed user units"
    else
        bad "failed user units: ${usr_failed[*]}"
    fi
fi

echo "== journal errors (hypr-de / vigil / greetd / waybar)"
errs=$(journalctl -b -p err --no-pager 2>/dev/null | grep -Ei 'vigil|greetd|waybar|hypr-de|workspace-zones' | grep -v 'gkr-pam' || true)
if [ -n "$errs" ]; then
    printf '%s\n' "$errs"
    bad "error-level journal lines for DE components (see above)"
else
    ok "no error-level journal lines for DE components"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "SECOND BOOT: PASS"
    exit 0
fi
echo "SECOND BOOT: FAIL"
exit 1
