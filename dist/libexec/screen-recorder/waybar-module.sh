#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/modules/base.sh" ]]; then
    source "$SCRIPT_DIR/modules/base.sh"
else
    PIDFILE="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is unset}/hypr-de/gpu-screen-recorder.pid"
    is_recording() {
        if [[ -f "$PIDFILE" ]]; then
            local pid
            pid=$(cat "$PIDFILE" 2>/dev/null)
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                return 0
            fi
        fi
        return 1
    }
fi

MODE="${1:-button}"

if is_recording; then
    if [[ "$MODE" == "spacer" ]]; then
        printf '{"text": "󰑊 REC", "tooltip": "", "class": "spacer"}\n'
    else
        printf '{"text": "󰑊 REC", "tooltip": "Screen recording in progress - click to stop", "class": "recording"}\n'
    fi
else
    printf '{"text": "", "tooltip": "", "class": "idle"}\n'
fi
