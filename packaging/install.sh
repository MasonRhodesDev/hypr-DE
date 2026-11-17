#!/bin/bash
set -euo pipefail

STAGE="${1:?usage: install.sh <staged-dist-dir> <destdir> main|gaming}"
DEST="${2:?destdir required}"
PART="${3:?part required: main|gaming}"
. "$(dirname "$0")/paths.conf"

inst()  { install -Dpm644 "$1" "$DEST$2"; }
instx() { install -Dpm755 "$1" "$DEST$2"; }

case "$PART" in
main)
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

    for f in "$STAGE"/bin/*; do
        instx "$f" "$BINDIR/$(basename "$f")"
    done
    (cd "$STAGE/libexec" && find . -type f) | while read -r f; do
        instx "$STAGE/libexec/$f" "$LIBEXECDIR/${f#./}"
    done

    (cd "$STAGE/systemd/user" && find . -type f) | while read -r f; do
        inst "$STAGE/systemd/user/$f" "$UNITDIR/${f#./}"
    done
    inst "$STAGE/systemd/user-preset/90-hypr-de.preset" "$PRESETDIR/90-hypr-de.preset"

    inst "$STAGE/uwsm/env"          "$XDGCONFDIR/uwsm/env"
    inst "$STAGE/uwsm/env-hyprland" "$XDGCONFDIR/uwsm/env-hyprland"
    inst "$STAGE/nvim/site/plugin/hypr-de-defaults.lua" "$NVIMSITE/plugin/hypr-de-defaults.lua"
    inst "$STAGE/nvim/site/colors/lmtt-material-you.lua" "$NVIMSITE/colors/lmtt-material-you.lua"
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
