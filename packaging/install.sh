#!/bin/bash
# Install the (already token-substituted) staged dist/ tree into DESTDIR.
# Shared by the RPM spec (%install) and PKGBUILD (package_*) so the file
# layout lives in exactly one place. paths.conf provides the target dirs.
#   usage: install.sh <staged-dist-dir> <destdir> {main|gaming}
set -euo pipefail

STAGE="${1:?usage: install.sh <staged-dist-dir> <destdir> main|gaming}"
DEST="${2:?destdir required}"
PART="${3:?part required: main|gaming}"
. "$(dirname "$0")/paths.conf"

inst()  { install -Dpm644 "$1" "$DEST$2"; }
instx() { install -Dpm755 "$1" "$DEST$2"; }

case "$PART" in
main)
    # /usr/share/hypr-de payload
    for f in "$STAGE"/hypr/*;   do inst "$f" "$DATADIR/hypr/$(basename "$f")"; done
    inst "$STAGE/waybar/config.jsonc" "$DATADIR/waybar/config.jsonc"
    inst "$STAGE/swaync/config.json"  "$DATADIR/swaync/config.json"
    inst "$STAGE/fuzzel/fuzzel.ini"   "$DATADIR/fuzzel/fuzzel.ini"
    inst "$STAGE/swappy/config"       "$DATADIR/swappy/config"
    inst "$STAGE/wallpapers/default.png" "$DATADIR/wallpapers/default.png"
    if [ -d "$STAGE/lmtt" ]; then
        (cd "$STAGE/lmtt" && find . -type f) | while read -r f; do
            inst "$STAGE/lmtt/$f" "$DATADIR/lmtt/${f#./}"
        done
    fi
    if [ -d "$STAGE/matugen" ]; then
        (cd "$STAGE/matugen" && find . -type f) | while read -r f; do
            inst "$STAGE/matugen/$f" "$DATADIR/matugen/${f#./}"
        done
    fi
    if [ -d "$STAGE/themes" ]; then
        (cd "$STAGE/themes" && find . -type f) | while read -r f; do
            inst "$STAGE/themes/$f" "$DATADIR/themes/${f#./}"
        done
    fi

    # binaries + libexec helpers
    for f in "$STAGE"/bin/*; do
        instx "$f" "$BINDIR/$(basename "$f")"
    done
    (cd "$STAGE/libexec" && find . -type f) | while read -r f; do
        instx "$STAGE/libexec/$f" "$LIBEXECDIR/${f#./}"
    done

    # systemd user units, drop-ins, preset
    (cd "$STAGE/systemd/user" && find . -type f) | while read -r f; do
        inst "$STAGE/systemd/user/$f" "$UNITDIR/${f#./}"
    done
    inst "$STAGE/systemd/user-preset/90-hypr-de.preset" "$PRESETDIR/90-hypr-de.preset"

    # uwsm env for the stock Hyprland (uwsm) session. No wayland-sessions
    # entry: hypr-DE is configs + deps, not a competing greeter session.
    inst "$STAGE/uwsm/env"          "$XDGCONFDIR/uwsm/env"
    inst "$STAGE/uwsm/env-hyprland" "$XDGCONFDIR/uwsm/env-hyprland"
    # System Neovim config: nvim sources the first $XDG_CONFIG_DIRS/nvim/
    # sysinit.vim before user config. Package-owned baseline + lmtt colors.
    inst "$STAGE/nvim/sysinit.vim" "$XDGCONFDIR/nvim/sysinit.vim"
    # vigil greeter defaults: the uwsm session must be the default or nothing
    # WantedBy=graphical-session.target (waybar, swaync) ever starts.
    inst "$STAGE/greetd/vigil.toml" "$GREETDDIR/vigil.toml"
    inst "$STAGE/environment.d/60-hypr-de.conf" "$ENVGENDIR/60-hypr-de.conf"
    inst "$STAGE/xdg/hypr/hyprland.lua" "$XDGCONFDIR/hypr/hyprland.lua"

    if [ -d "$STAGE/man" ]; then
        for f in "$STAGE"/man/*; do
            [ -f "$f" ] || continue
            sec="${f##*.}"
            inst "$f" "$MANDIR/man${sec}/$(basename "$f")"
        done
    fi
    ;;
gaming)
    inst  "$STAGE/gaming/game-rules.lua" "$DATADIR/gaming/game-rules.lua"
    instx "$STAGE/gaming/bp-game-focus.py" "$LIBEXECDIR/bp-game-focus.py"
    instx "$STAGE/gaming/steam-clean-shutdown.sh" "$LIBEXECDIR/steam-clean-shutdown.sh"
    instx "$STAGE/gaming/steam-set-launch-options" "$BINDIR/steam-set-launch-options"
    inst  "$STAGE/gaming/bp-game-focus.service" "$UNITDIR/bp-game-focus.service"
    inst  "$STAGE/gaming/steam-clean-shutdown.service" "$UNITDIR/steam-clean-shutdown.service"
    inst  "$STAGE/gaming/90-hypr-de-gaming.preset" "$PRESETDIR/90-hypr-de-gaming.preset"
    inst  "$STAGE/gaming/app-scope-steam-clean-shutdown.conf" "$UNITDIR/app-.scope.d/steam-clean-shutdown.conf"
    inst  "$STAGE/gaming/gaming.conf" "$ENVGENDIR/70-hypr-de-gaming.conf"
    ;;
*)
    echo "unknown part: $PART" >&2; exit 2 ;;
esac
