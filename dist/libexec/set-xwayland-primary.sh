#!/bin/bash
# Set the XWayland primary output to a chosen monitor (matched by model
# substring). Fixes XWayland games/apps launching on the wrong monitor in
# multi-monitor setups. Opt-in: does nothing until you name a monitor.
#
# Configure the model substring in either:
#   ~/.config/hypr-de/xwayland-primary        (file: one model substring)
#   $HYPR_DE_XWAYLAND_PRIMARY_MODEL           (env var, wins over the file)
# Find your model with: hyprctl monitors -j | jq -r '.[].model'

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/hypr-de/xwayland-primary"
MODEL="${HYPR_DE_XWAYLAND_PRIMARY_MODEL:-}"
if [[ -z "$MODEL" && -r "$CONFIG" ]]; then
    MODEL=$(head -n1 "$CONFIG" | tr -d '[:space:]')
fi

# Unconfigured is the silent default — most setups don't need this.
[[ -z "$MODEL" ]] && exit 0

OUTPUT=$(hyprctl monitors -j | jq -r --arg m "$MODEL" '.[] | select(.model | contains($m)) | .name')

if [[ -n "$OUTPUT" ]]; then
    xrandr --output "$OUTPUT" --primary
    echo "$(date): Set $OUTPUT as XWayland primary"
else
    echo "$(date): XWayland-primary monitor (model ~ $MODEL) not connected"
fi
