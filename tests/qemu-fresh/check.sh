#!/bin/bash
# Second-boot checks for a hypr-DE QEMU guest. Run on the guest (or via ssh).
# Exit 0 only when packaged login path, man pages, plugins, and units look sane.
set -euo pipefail

fail=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

# arch or fedora — picks the package tool and per-distro file paths below.
if command -v pacman >/dev/null; then
    DISTRO=arch
    LIBDIR=/usr/lib
else
    DISTRO=fedora
    LIBDIR=/usr/lib64
fi

pkg_version() {
    if [ "$DISTRO" = arch ]; then
        pacman -Q "$1" 2>/dev/null | awk '{print $2}' | sed 's/-.*//'
    else
        rpm -q --qf '%{VERSION}' "$1" 2>/dev/null
    fi
}

pkg_at_least() {
    local pkg=$1 want=$2 have
    have=$(pkg_version "$pkg") && [ -n "$have" ] || {
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
pkg_at_least vigil 0.3.0
pkg_at_least dials 0.4.0
pkg_at_least lmtt 0.3.1
pkg_at_least hyprstate 2.4.2
if pkg_version hyprstate-gui >/dev/null 2>&1 && [ -n "$(pkg_version hyprstate-gui)" ]; then
    bad "hyprstate-gui is still installed (renamed to dials)"
else
    ok "no hyprstate-gui package"
fi
pkg_at_least waybar-workspace-buttons 1.1.2
pkg_at_least man-db 2.0
pkg_at_least waybar 0.15
pkg_at_least greetd 0.10

echo "== files"
files=(
    /usr/bin/man
    /usr/bin/vigil
    /usr/bin/hypr-de-setup
    /usr/bin/hypr-de-help
    /usr/share/man/man7/hypr-de.7.gz
    /usr/share/man/man7/workspace-zones.7.gz
    /usr/share/man/man1/hypr-de-help.1.gz
    "$LIBDIR/waybar/workspace_buttons.so"
    /etc/xdg/hypr/hyprland.lua
    /usr/share/hypr-de/waybar/config.jsonc
    /usr/share/vigil/slint-kit/ui/theme.slint
)
# The workspace-zones Hyprland plugin is packaged on Arch only; on Fedora it
# is ABI-locked to the compositor and installed via hyprpm (main.lua probes
# both packaged paths and ~/.local, so its absence is not a failure there).
[ "$DISTRO" = arch ] && files+=(/usr/lib/hyprland/plugins/libworkspace-zones.so)
for f in "${files[@]}"
do
    if [ -e "$f" ]; then
        ok "$f"
    else
        bad "missing $f"
    fi
done

echo "== lmtt styles"
# These only exist after hypr-de-setup applies the packaged gradient theme.
lmtt_files=(
    "$HOME/.config/hypr-de/theme"
    "$HOME/.config/hypr/lmtt-colors.lua"
    "$HOME/.config/hypr-de/waybar.css"
)
for f in "${lmtt_files[@]}"
do
    if [ -e "$f" ]; then
        ok "$f"
    else
        bad "missing $f (hypr-de-setup should apply gradient on firstboot)"
    fi
done

echo "== config"
if grep -q 'command = "/usr/bin/vigil"' /etc/greetd/config.toml 2>/dev/null; then
    ok "greetd command is vigil"
else
    bad "greetd is not pointed at /usr/bin/vigil"
fi
# Without this default vigil picks the plain "Hyprland" entry (sorts first),
# uwsm never runs, graphical-session.target stays inactive, and waybar/swaync
# silently never start on a fresh install.
if grep -q 'default = "Hyprland (uwsm-managed)"' /etc/greetd/vigil.toml 2>/dev/null; then
    ok "vigil default session is uwsm-managed"
else
    bad "vigil.toml missing or default session is not Hyprland (uwsm-managed)"
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

echo "== fonts / icons"
# The waybar/swaync stylesheets request these families by name; without them
# every glyph is tofu (Fedora shipped zero Nerd fonts before hypr-de-extras).
# Snapshot once. NOT `fc-list | grep -q`: under pipefail grep -q's early
# exit SIGPIPEs fc-list and the pipeline "fails" whenever the font list is
# long enough — an intermittent false negative.
fonts=$(fc-list 2>/dev/null || true)
if grep -qi "JetBrainsMono Nerd Font" <<<"$fonts"; then
    ok "JetBrainsMono Nerd Font present"
else
    bad "JetBrainsMono Nerd Font missing"
fi
if grep -qi "Symbols Nerd Font" <<<"$fonts"; then
    ok "Symbols Nerd Font present"
else
    bad "Symbols Nerd Font missing"
fi
# adwaita-icon-theme dropped app icons; Papirus supplies them for fuzzel/GTK.
if [ -f /usr/share/icons/Papirus/index.theme ]; then
    ok "Papirus icon theme installed"
else
    bad "Papirus icon theme missing"
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
# Arch's greetd runs the greeter as "greeter", Fedora's as "greetd".
greeter_user=greeter
[ "$DISTRO" = fedora ] && greeter_user=greetd
if pgrep -u "$greeter_user" -x vigil >/dev/null; then
    ok "vigil running as $greeter_user"
else
    bad "no vigil process as $greeter_user"
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

echo "== dials (settings window)"
for f in /usr/bin/dials /usr/share/applications/dials.desktop /usr/share/applications/lmtt-config.desktop
do
    if [ -e "$f" ]; then ok "$f"; else bad "$f missing"; fi
done
if entries=$(dials --entries 2>&1); then
    if printf '%s\n' "$entries" | grep -q $'^Appearance\tlmtt-config\t'; then
        ok "dials --entries lists lmtt-config under Appearance"
    else
        printf '%s\n' "$entries"
        bad "dials --entries does not list lmtt-config"
    fi
else
    printf '%s\n' "$entries"
    bad "dials --entries failed"
fi

echo "== editor + nvim theme"
pkg_at_least neovim 0.9
if command -v nvim >/dev/null; then ok "nvim on PATH"; else bad "nvim missing (default editor)"; fi
ed="${EDITOR:-}"
if [ -n "$ed" ] && command -v "${ed%% *}" >/dev/null; then
    ok "EDITOR=$ed resolves"
else
    bad "EDITOR unset or not on PATH (=$ed)"
fi
if [ -f "$HOME/.config/hypr-de/nvim-colors.lua" ] && grep -q 'colors_name' "$HOME/.config/hypr-de/nvim-colors.lua"; then
    ok "nvim Material You colorscheme rendered"
else
    bad "nvim-colors.lua missing or empty"
fi
if [ -f /etc/xdg/nvim/sysinit.vim ]; then ok "/etc/xdg/nvim/sysinit.vim"; else bad "system nvim sysinit missing"; fi

echo "== workspace button click dispatch"
# Older modules used "hyprctl dispatch workspace N"; newer Hyprland parses
# dispatch args as Lua and rejects that, so clicks silently did nothing.
wsb_so="$LIBDIR/waybar/workspace_buttons.so"
if ! command -v strings >/dev/null; then
    ok "skipped dispatcher check (no strings/binutils in guest)"
elif grep -aq 'hl.dsp.focus' "$wsb_so" 2>/dev/null; then
    ok "workspace buttons use the Lua dispatcher"
elif grep -aq 'dispatch workspace' "$wsb_so" 2>/dev/null; then
    bad "workspace buttons use the classic dispatcher — clicks are a no-op on Hyprland with Lua config"
else
    bad "could not determine the workspace-button dispatcher ($wsb_so)"
fi

echo "== idle inhibitor tray (waybar indicator)"
pkg_at_least logind-idle-control 0.2.3
if [ -x /usr/bin/logind-idle-control-tray ]; then ok "logind-idle-control-tray binary"; else bad "idle-control tray binary missing"; fi
case "$(systemctl --user is-enabled logind-idle-control-tray.service 2>/dev/null)" in
    enabled) ok "logind-idle-control-tray.service enabled (idle inhibitor shows in tray)" ;;
    *) bad "logind-idle-control-tray.service not enabled — no idle inhibitor in waybar" ;;
esac

echo "== swaync background (control-center not transparent)"
if grep -q '@define-color background' "$HOME/.config/hypr-de/swaync.css" 2>/dev/null; then
    ok "swaync background color defined inline"
else
    bad "swaync background undefined — control-center would be transparent"
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
