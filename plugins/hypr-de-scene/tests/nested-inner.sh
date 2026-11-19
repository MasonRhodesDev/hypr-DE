#!/bin/bash
set -uo pipefail
hyprland=$1 plugin=$2 data=$3 out=$4 mode=$5 splash=$6
chmod 700 "$XDG_RUNTIME_DIR"
ulimit -c 0

cat >"$out/sway.conf" <<'CONF'
output HEADLESS-1 resolution 1920x1080
default_border none
for_window [app_id=".*"] fullscreen enable
CONF

WLR_BACKENDS=headless WLR_RENDERER=gles2 WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDER_DRM_DEVICE=$RENDER_NODE \
    sway -c "$out/sway.conf" >"$out/sway.log" 2>&1 &
sway_pid=$!
for _ in $(seq 100); do
    [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break
    sleep 0.1
done
[ -S "$XDG_RUNTIME_DIR/wayland-1" ] || { echo "nested-readback: sway did not start, see $out/sway.log" >&2; exit 1; }

{
    echo 'hl.config({ misc = { disable_hyprland_logo = true, disable_splash_rendering = true, background_color = "rgb(203040)" } })'
    echo 'hl.config({ animations = { enabled = true } })'
    echo 'hl.monitor({ output = "HEADLESS-2", mode = "3440x1440@60", position = "auto", scale = 1 })'
    echo 'hl.monitor({ output = "HEADLESS-3", mode = "3840x2160@60", position = "auto", scale = 1.5, transform = 3 })'
    echo 'hl.monitor({ output = "HEADLESS-4", mode = "1920x1080@60", position = "auto", scale = 1 })'
    echo 'hl.monitor({ output = "HEADLESS-5", mode = "3840x2160@60", position = "auto", scale = 1.5, transform = 1 })'
    [ "$mode" != none ] && echo "hl.plugin.load(\"$plugin\")"
    if [ -n "$splash" ]; then
        echo 'hl.layer_rule({ name = "handoff", match = { namespace = "desktop-boot-splash" }, no_anim = true })'
        echo "hl.on(\"hyprland.start\", function() hl.exec_cmd(\"$splash\") end)"
    fi
} >"$out/hyprland.lua"

(
    export WAYLAND_DISPLAY=wayland-1
    n=0
    while [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && [ "$n" -lt 150 ]; do
        grim -t ppm "$out/shots/$(printf '%03d' "$n").ppm" 2>/dev/null
        n=$((n + 1))
        sleep 0.1
    done
) &
shots_pid=$!

export HYPR_DE_SCENE_DUMP="$out/dumps" HYPR_DE_SCENE_DATA="$data" HYPR_DE_SCENE_TIMEOUT="$SCENE_TIMEOUT"
[ "$mode" = probe ] && export HYPR_DE_SCENE_MODE=probe
export DESKTOP_BOOT_DATA="$data" DESKTOP_BOOT_MAX_SECONDS=4 DESKTOP_BOOT_MIN_SECONDS=1

WAYLAND_DISPLAY=wayland-1 "$hyprland" -c "$out/hyprland.lua" >"$out/hyprland.log" 2>&1 &
hypr_pid=$!

sig=
for _ in $(seq 100); do
    sig=$(ls "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -n1)
    [ -n "$sig" ] && [ -S "$XDG_RUNTIME_DIR/hypr/$sig/.socket.sock" ] && break
    sleep 0.1
done
if [ -z "$sig" ]; then
    echo "nested-readback: Hyprland did not start, see $out/hyprland.log" >&2
    kill "$sway_pid" 2>/dev/null
    exit 1
fi

sleep 1.5
for name in HEADLESS-2 HEADLESS-3 HEADLESS-4 HEADLESS-5; do
    hyprctl -i "$sig" output create headless "$name" >>"$out/hyprctl.log" 2>&1
done
sleep "$SCENE_RUN_SECONDS"
hyprctl -i "$sig" monitors >"$out/monitors.txt" 2>&1
cp "$XDG_RUNTIME_DIR/hypr/$sig/hyprland.log" "$out/hyprland-full.log" 2>/dev/null

alive=0
kill -0 "$hypr_pid" 2>/dev/null && alive=1
kill "$hypr_pid" 2>/dev/null
wait "$hypr_pid" 2>/dev/null
kill "$shots_pid" "$sway_pid" 2>/dev/null
wait 2>/dev/null

if [ "$alive" != 1 ]; then
    echo "nested-readback: Hyprland exited on its own, see $out/hyprland.log" >&2
    exit 1
fi
echo "nested-readback: done, $(ls "$out/dumps" | wc -l) dumps and $(ls "$out/shots" | wc -l) shots in $out"
