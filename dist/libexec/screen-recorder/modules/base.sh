#!/bin/bash
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    echo "screen-recorder: XDG_RUNTIME_DIR is unset; refusing to keep state in /tmp" >&2
    exit 1
fi
RECORDER_STATE_DIR="$XDG_RUNTIME_DIR/hypr-de"
mkdir -p "$RECORDER_STATE_DIR" && chmod 700 "$RECORDER_STATE_DIR" || {
    echo "screen-recorder: cannot use $RECORDER_STATE_DIR" >&2
    exit 1
}
STATE_FILE="$RECORDER_STATE_DIR/screen-recorder-state"
PIDFILE="$RECORDER_STATE_DIR/gpu-screen-recorder.pid"

get_recording_pid() {
    if [[ -f "$PIDFILE" ]]; then
        cat "$PIDFILE" 2>/dev/null
    fi
}

is_recording() {
    local pid comm
    pid=$(get_recording_pid)
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        comm=$(cat "/proc/$pid/comm" 2>/dev/null)
        case "$comm" in
            gpu-screen-reco*) return 0 ;;
        esac
    fi
    if [[ -f "$PIDFILE" ]]; then
        rm -f "$PIDFILE" "$STATE_FILE"
    fi
    return 1
}

get_output_file() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE" 2>/dev/null
    fi
}

set_output_file() {
    local filename="$1"
    echo "$filename" > "$STATE_FILE"
}

clear_state() {
    rm -f "$STATE_FILE" "$PIDFILE"
}

refresh_waybar() {
    pkill -SIGRTMIN+10 waybar
}
