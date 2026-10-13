#!/bin/bash
# A wallpaper set anywhere reaches the desktop without a re-login.
#
# dials and `lmtt wallpaper set` write the appearance registry; vigil reads
# it directly, but swaybg reads it only when it starts and hyprlock reads
# its own $WALLPAPER file. hypr-de-wallpaper-sync, run by the
# hypr-de-wallpaper lmtt module after every `lmtt switch`, closes that gap
# and must restart nothing when the wallpaper did not change (SUPER+T must
# not flicker). Stubs: a swaybg that only sleeps, so /proc shows the argv a
# real one has; a systemctl that reports its PID and records restarts.
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
cleanup() { [ -f "$work/swaybg.pid" ] && kill "$(cat "$work/swaybg.pid")" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

mkdir -p "$work/bin" "$work/share/wallpapers" "$work/cfg/appearance-profiles"
sed "s|@DATADIR@|$work/share|g" "$root/dist/libexec/hypr-de-wallpaper-sync" > "$work/sync"
chmod +x "$work/sync"
# A swaybg that keeps its argv visible in /proc and goes away on TERM.
printf '#!/bin/sh\ntrap '"'"'kill $child'"'"' TERM\nsleep 60 & child=$!\nwait\n' > "$work/bin/swaybg"
chmod +x "$work/bin/swaybg"
# systemctl: MainPID of our stub, and a record of every restart.
cat > "$work/bin/systemctl" <<STUB
#!/bin/sh
case "\$*" in
    *"show -p MainPID"*) cat "$work/swaybg.pid" 2>/dev/null || echo 0 ;;
    *try-restart*) echo restart >> "$work/restarts" ;;
esac
STUB
chmod +x "$work/bin/systemctl"
: > "$work/share/wallpapers/default.png"
: > "$work/cfg/mine.png"
: > "$work/cfg/my wall.png"

show() {  # (re)start the stub swaybg on an image, as swaybg-launch would
    [ -f "$work/swaybg.pid" ] && kill "$(cat "$work/swaybg.pid")" 2>/dev/null
    "$work/bin/swaybg" -i "$1" -m fill & echo $! > "$work/swaybg.pid"
    sleep 0.1
}
registry() { printf 'version = 1\n\n[background]\npath = "%s"\n\n[output]\n' "$1" > "$work/cfg/appearance-profiles/default.toml"; }
run() { HOME="$work" XDG_CONFIG_HOME="$work/cfg" PATH="$work/bin:$PATH" WAYLAND_DISPLAY="${WD-wayland-1}" "$work/sync" 2>"$work/err"; }
restarts() { wc -l < "$work/restarts" 2>/dev/null || echo 0; }
lockconf() { cat "$work/cfg/hypr-de/wallpaper.conf" 2>/dev/null; }

echo "== a new registry wallpaper restarts swaybg and rewrites the hyprlock conf"
show "$work/share/wallpapers/default.png"
registry "$work/cfg/mine.png"
run
[ "$(restarts)" = 1 ] && ok "swaybg restarted once" || bad "restarts: $(restarts)"
[ "$(lockconf)" = "\$WALLPAPER = $work/cfg/mine.png" ] && ok "hyprlock conf follows" || bad "hyprlock conf: $(lockconf)"
[ "$(cat "$work/cfg/environment.d/wallpaper.conf")" = "WALLPAPER_PATH=$work/cfg/mine.png" ] && ok "environment.d follows" || bad "environment.d: $(cat "$work/cfg/environment.d/wallpaper.conf")"

echo "== the same wallpaper again (a theme toggle) restarts and rewrites nothing"
show "$work/cfg/mine.png"
touch -d '2000-01-01' "$work/cfg/hypr-de/wallpaper.conf"
run
[ "$(restarts)" = 1 ] && ok "no restart" || bad "restarts: $(restarts)"
[ "$(stat -c %Y "$work/cfg/hypr-de/wallpaper.conf")" = "$(date -d '2000-01-01' +%s)" ] && ok "hyprlock conf untouched" || bad "hyprlock conf rewritten"

echo "== a path with a space is compared as one argument"
registry "$work/cfg/my wall.png"
run
[ "$(restarts)" = 2 ] && ok "restart for the new image" || bad "restarts: $(restarts)"
show "$work/cfg/my wall.png"
run
[ "$(restarts)" = 2 ] && ok "no restart once it shows" || bad "restarts: $(restarts)"
[ "$(lockconf)" = "\$WALLPAPER = $work/cfg/my wall.png" ] && ok "space survives in the conf" || bad "conf: $(lockconf)"

echo "== without a compositor the files are written but nothing is restarted"
registry "$work/cfg/mine.png"
WD= run
[ "$(restarts)" = 2 ] && ok "no restart without WAYLAND_DISPLAY" || bad "restarts: $(restarts)"
[ "$(lockconf)" = "\$WALLPAPER = $work/cfg/mine.png" ] && ok "conf still written" || bad "conf: $(lockconf)"

echo "== no swaybg running: nothing to restart"
kill "$(cat "$work/swaybg.pid")" 2>/dev/null; rm -f "$work/swaybg.pid"
run
[ "$(restarts)" = 2 ] && ok "no restart with MainPID 0" || bad "restarts: $(restarts)"

echo "== no registry: the packaged default, like swaybg-launch"
rm "$work/cfg/appearance-profiles/default.toml"
show "$work/share/wallpapers/default.png"
run
[ "$(restarts)" = 2 ] && ok "default already shown, no restart" || bad "restarts: $(restarts)"
[ "$(lockconf)" = "\$WALLPAPER = $work/share/wallpapers/default.png" ] && ok "conf names the default" || bad "conf: $(lockconf)"

echo "== the module runs the sync after every switch"
grep -q '^\[reload\]' "$root/dist/lmtt/modules/hypr-de-wallpaper.toml" \
    && grep -q 'hypr-de-wallpaper-sync' "$root/dist/lmtt/modules/hypr-de-wallpaper.toml" \
    && ok "hypr-de-wallpaper.toml is a reload module on the sync" || bad "module does not run the sync"

exit $fail
