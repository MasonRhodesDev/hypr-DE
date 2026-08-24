#!/bin/bash
# Shared state for the screen recorder.
#
# State lives under $XDG_RUNTIME_DIR (0700, per-user, cleared at logout),
# never /tmp. /tmp/screen-recorder-state and /tmp/gpu-screen-recorder.pid
# were predictable names in a world-writable directory: another local user
# could pre-create either as a symlink and have this script overwrite a file
# of their choosing as us, seed the pidfile so the stop keybind sent SIGINT
# to a process they picked, or seed the state file so the path announced and
# copied to the clipboard was theirs.
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
    # Confirm the pid is still the recorder: a recycled pid would otherwise
    # take the SIGINT the stop keybind sends.
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        comm=$(cat "/proc/$pid/comm" 2>/dev/null)
        case "$comm" in
            gpu-screen-record*) return 0 ;;
        esac
    fi
    # Clean up stale PID file
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
