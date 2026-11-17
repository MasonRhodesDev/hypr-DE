#!/bin/bash

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
XWAYLAND_PRIMARY_SCRIPT="@LIBEXECDIR@/set-xwayland-primary.sh"

: "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is unset; refusing to keep the lock in /tmp}"
LOCKDIR="$XDG_RUNTIME_DIR/hypr-de"
mkdir -p "$LOCKDIR" && chmod 700 "$LOCKDIR"
LOCKFILE="$LOCKDIR/${SCRIPT_NAME}.lock"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "Another instance is already running (holds $LOCKFILE)"
    exit 1
fi

trap 'exit 0' INT TERM

echo "Starting Hyprland event listener (PID: $$)"

if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    echo "ERROR: HYPRLAND_INSTANCE_SIGNATURE not set"
    exit 1
fi

socket_path="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
if [[ ! -e "$socket_path" ]]; then
    echo "ERROR: Hyprland socket not found at $socket_path"
    exit 1
fi

echo "Monitoring Hyprland events via $socket_path"

check_bar() {
    systemctl --user start --no-block waybar-watchdog.service 2>/dev/null || true
}

if [[ -x "$XWAYLAND_PRIMARY_SCRIPT" ]]; then
    (sleep 2 && "$XWAYLAND_PRIMARY_SCRIPT") &
fi

socat -U - "UNIX-CONNECT:$socket_path" | while IFS= read -r line; do
    case "$line" in
        "configreloaded>>")
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Config reloaded, restarting waybar..."
            (sleep 1 && systemctl --user restart waybar) &
            ;;
        monitoradded\>\>*|monitoraddedv2\>\>*)
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Monitor change: $line"
            if [[ -x "$XWAYLAND_PRIMARY_SCRIPT" ]]; then
                (sleep 1 && "$XWAYLAND_PRIMARY_SCRIPT") &
            fi
            name="${line#*>>}"; name="${name%%,*}"
            case "$line" in monitoraddedv2*) name=$(printf '%s' "${line#*>>}" | cut -d, -f2);; esac
            (sleep 2 && "@LIBEXECDIR@/blank-guard.sh" "$name") &
            check_bar
            ;;
        monitorremoved\>\>*)
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Monitor change: $line"
            if [[ -x "$XWAYLAND_PRIMARY_SCRIPT" ]]; then
                (sleep 1 && "$XWAYLAND_PRIMARY_SCRIPT") &
            fi
            check_bar
            ;;
    esac
done
