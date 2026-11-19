#!/bin/bash
set -uo pipefail
hyprland=$1 plugin=$2 data=$3 out=$4 case=$5
chmod 700 "$XDG_RUNTIME_DIR"
ulimit -c 0

wallpaper_color=ff8000

cat >"$out/sway.conf" <<'CONF'
output HEADLESS-1 resolution 1920x1080
default_border none
for_window [app_id=".*"] fullscreen enable
CONF

WLR_BACKENDS=headless WLR_RENDERER=gles2 WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDER_DRM_DEVICE=$RENDER_NODE \
    sway -c "$out/sway.conf" >"$out/sway.log" 2>&1 &
sway_pid=$!
for _ in $(seq 100); do
    [[ -S "$XDG_RUNTIME_DIR/wayland-1" ]] && break
    sleep 0.1
done
[[ -S "$XDG_RUNTIME_DIR/wayland-1" ]] || { echo "nested-readback: sway did not start, see $out/sway.log" >&2; exit 1; }

own_wallpaper=true
[[ "$case" = N2b ]] && own_wallpaper=false
{
    echo "hl.config({ misc = { disable_hyprland_logo = $own_wallpaper, disable_splash_rendering = true, disable_watchdog_warning = true, background_color = \"rgb(203040)\" } })"
    echo 'hl.config({ animations = { enabled = true } })'
    if [[ "$case" = readback ]]; then
        echo 'hl.monitor({ output = "HEADLESS-2", mode = "3440x1440@60", position = "auto", scale = 1 })'
        echo 'hl.monitor({ output = "HEADLESS-3", mode = "3840x2160@60", position = "auto", scale = 1.5, transform = 3 })'
        echo 'hl.monitor({ output = "HEADLESS-4", mode = "1920x1080@60", position = "auto", scale = 1 })'
        echo 'hl.monitor({ output = "HEADLESS-5", mode = "3840x2160@60", position = "auto", scale = 1.5, transform = 1 })'
        echo 'hl.monitor({ output = "HEADLESS-6", mode = "1600x900@60", position = "auto", scale = 1, transform = 2 })'
        echo 'hl.monitor({ output = "HEADLESS-7", mode = "1366x768@60", position = "auto", scale = 1, transform = 4 })'
        echo 'hl.monitor({ output = "HEADLESS-8", mode = "1680x1050@60", position = "auto", scale = 1, transform = 5 })'
        echo 'hl.monitor({ output = "HEADLESS-9", mode = "1440x900@60", position = "auto", scale = 1, transform = 6 })'
        echo 'hl.monitor({ output = "HEADLESS-10", mode = "1280x1024@60", position = "auto", scale = 1, transform = 7 })'
    else
        for n in 2 3 4 5; do
            echo "hl.monitor({ output = \"HEADLESS-$n\", mode = \"1280x720@60\", position = \"auto\", scale = 1 })"
        done
    fi
    echo "hl.plugin.load(\"$plugin\")"
} >"$out/hyprland.lua"

python3 -I - "$out/shots" <<'PY' &
import os, subprocess, sys, time
shots = sys.argv[1]
with open(os.path.join(shots, "times"), "w") as times:
    for n in range(150):
        if not os.path.exists(os.path.join(os.environ["XDG_RUNTIME_DIR"], "wayland-1")):
            break
        name = f"{n:03d}.ppm"
        taken = time.monotonic()
        if subprocess.run(["grim", "-t", "ppm", os.path.join(shots, name)], env=dict(os.environ, WAYLAND_DISPLAY="wayland-1"), capture_output=True).returncode == 0:
            times.write(f"{name} {taken:.3f}\n")
            times.flush()
        time.sleep(max(0.0, taken + 0.1 - time.monotonic()))
PY
shots_pid=$!

export HYPR_DE_SCENE_DUMP="$out/dumps" HYPR_DE_SCENE_DATA="$data"
export HYPR_DE_SCENE_TIMEOUT=5 HYPR_DE_SCENE_QUIET=1.5 HYPR_DE_SCENE_SPREAD=0.25 HYPR_DE_SCENE_FADE=0.2
# Hyprland run by a service manager, so the session is awaited
export MANAGERPID=1
case $case in
    readback) export HYPR_DE_SCENE_TIMEOUT=$SCENE_TIMEOUT HYPR_DE_SCENE_QUIET=$SCENE_TIMEOUT ;;
    N5) export HYPR_DE_SCENE_SPREAD=3 ;;
    N9) unset MANAGERPID ;;
    N10) export HYPR_DE_SCENE_TIMEOUT=9 HYPR_DE_SCENE_QUIET=9 ;;
    *) ;;
esac

WAYLAND_DISPLAY=wayland-1 "$hyprland" -c "$out/hyprland.lua" >"$out/hyprland.log" 2>&1 &
hypr_pid=$!
unset MANAGERPID

sig=
for _ in $(seq 100); do
    for dir in "$XDG_RUNTIME_DIR"/hypr/*/; do
        [[ -S "$dir.socket.sock" ]] && sig=$(basename -- "$dir")
    done
    [[ -n "$sig" ]] && break
    sleep 0.1
done
if [[ -z "$sig" ]]; then
    echo "nested-readback: Hyprland did not start, see $out/hyprland.log" >&2
    kill "$sway_pid" 2>/dev/null
    exit 1
fi
display=
for _ in $(seq 50); do
    for socket in "$XDG_RUNTIME_DIR"/wayland-*; do
        [[ -S "$socket" && "$socket" != "$XDG_RUNTIME_DIR/wayland-1" ]] && display=$(basename -- "$socket")
    done
    [[ -n "$display" ]] && break
    sleep 0.1
done

hc() { hyprctl -i "$sig" "$@" >>"$out/hyprctl.log" 2>&1; }
scene() { printf '> scene %s\n' "$*" >>"$out/hyprctl.log"; hc scene "$@"; }
client() { WAYLAND_DISPLAY=$display "$@" >>"$out/clients.log" 2>&1 & }
paint() {
    local args=()
    for name in "$@"; do args+=(-o "$name" -c "$wallpaper_color"); done
    client swaybg "${args[@]}"
}
state() { hyprctl -i "$sig" -j scene >"$out/$1.json" 2>&1; }

if [[ "$case" != readback ]]; then
    for n in 2 3 4; do hc output create headless "HEADLESS-$n"; done
fi

case $case in
    readback)
        sleep 1.5
        for n in 2 3 4 5 6 7 8 9 10; do hc output create headless "HEADLESS-$n"; done
        sleep "$SCENE_RUN_SECONDS"
        ;;
    N1) sleep 1; scene ready session ;;
    N2) scene expect layer wallpaper; scene ready session; sleep 1; paint '*' ;;
    N2b) scene ready session ;;
    N3) ;;
    N4) scene expect layer waybar; scene ready session ;;
    N5)
        scene expect layer wallpaper
        paint WAYLAND-1 HEADLESS-2 HEADLESS-3 HEADLESS-4
        sleep 0.5; hc output create headless HEADLESS-5
        sleep 0.5; scene ready session
        sleep 0.5; paint HEADLESS-5
        ;;
    N6) scene expect layer wallpaper; scene ready session; sleep 0.5; paint WAYLAND-1 ;;
    N7) scene expect layer waybar; scene ready session; sleep 1; client hyprlock --no-fade-in --immediate-render -c /dev/null ;;
    N8)
        scene expect layer waybar; scene ready session
        scene expect layer 'bad"name'; scene expect layer aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; scene expect window foot
        for n in $(seq 40); do scene expect layer "extra$n"; done
        state held
        scene release test
        scene expect layer late
        sleep 0.5; state after
        ;;
    N9) ;;
    N10)
        client foot -e sh -c "cat >'$out/typed'"
        sleep 1.5
        WAYLAND_DISPLAY=$display wtype hello
        sleep 0.3; state typed
        WAYLAND_DISPLAY=$display wtype -k F2
        sleep 0.3; state plain
        WAYLAND_DISPLAY=$display wtype -M ctrl -M alt -k F2 -m alt -m ctrl
        sleep 0.3; state chord
        scene release test
        sleep 0.6
        # wtype sends its own keymap first, and a key in the same instant can be lost
        WAYLAND_DISPLAY=$display wtype -s 300 world -k Return
        sleep 0.5
        ;;
    *) echo "nested-readback: no case $case" >&2 ;;
esac

for _ in $(seq 120); do
    grep -q '^scene: released' "$out/dumps/log" 2>/dev/null && break
    sleep 0.1
done
sleep 1
state final
hyprctl -i "$sig" monitors >"$out/monitors.txt" 2>&1
# Hyprland lists a plugin only when its load succeeded, and only a failed load puts a notification on screen
hyprctl -i "$sig" plugin list >"$out/plugins.txt" 2>&1

if [[ "$SCENE_UNLOAD" = 1 ]]; then
    hyprctl -i "$sig" plugin unload "$plugin" >"$out/unload.txt" 2>&1
    sleep "$SCENE_AFTER_UNLOAD"
    hyprctl -i "$sig" plugin list >>"$out/unload.txt" 2>&1
fi
cp "$XDG_RUNTIME_DIR/hypr/$sig/hyprland.log" "$out/hyprland-full.log" 2>/dev/null

alive=0
kill -0 "$hypr_pid" 2>/dev/null && alive=1
kill "$hypr_pid" 2>/dev/null
wait "$hypr_pid" 2>/dev/null
stopped=$?
kill "$shots_pid" "$sway_pid" 2>/dev/null
wait 2>/dev/null

if [[ "$alive" != 1 ]]; then
    echo "nested-readback: Hyprland exited on its own, see $out/hyprland.log and $out/unload.txt" >&2
    exit 1
fi
if [[ "$stopped" != 0 ]]; then
    echo "nested-readback: Hyprland ended with status $stopped when told to stop, see $out/hyprland.log" >&2
    exit 1
fi
echo "nested-readback: $case done in $out"
