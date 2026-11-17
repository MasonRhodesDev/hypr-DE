#!/bin/bash

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/hypr-de/xwayland-primary"
MODEL="${HYPR_DE_XWAYLAND_PRIMARY_MODEL:-}"
if [[ -z "$MODEL" && -r "$CONFIG" ]]; then
    MODEL=$(head -n1 "$CONFIG" | tr -d '[:space:]')
fi

[[ -z "$MODEL" ]] && exit 0

OUTPUT=$(hyprctl monitors -j | jq -r --arg m "$MODEL" '.[] | select(.model | contains($m)) | .name')

if [[ -n "$OUTPUT" ]]; then
    xrandr --output "$OUTPUT" --primary
    echo "$(date): Set $OUTPUT as XWayland primary"
else
    echo "$(date): XWayland-primary monitor (model ~ $MODEL) not connected"
fi
