#!/bin/bash
# Hyprland event listener
# Monitors Hyprland IPC for various events:
# - configreloaded: restarts waybar (prevents freeze from hyprctl reload)
# - monitor changes: sets XWayland primary to ultrawide

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
XWAYLAND_PRIMARY_SCRIPT="@LIBEXECDIR@/set-xwayland-primary.sh"

# Singleton guard, conforming to desktop-commons' singleton-guard-v1:
# flock(2) on $XDG_RUNTIME_DIR/<name>.lock, held for the process's whole
# lifetime, and the lock file is NEVER unlinked -- unlinking it is what lets
# two starts race onto different inodes and both believe they are the owner.
#
# The previous guard wrote a pid into /tmp/<name>.lock and trusted it. That
# is both non-conforming and attackable: a predictable path in a
# world-writable directory can be pre-planted as a symlink (we write our pid
# through it) or seeded with a live pid so this listener never starts again.
: "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is unset; refusing to keep the lock in /tmp}"
LOCKDIR="$XDG_RUNTIME_DIR/hypr-de"
mkdir -p "$LOCKDIR" && chmod 700 "$LOCKDIR"
LOCKFILE="$LOCKDIR/${SCRIPT_NAME}.lock"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "Another instance is already running (holds $LOCKFILE)"
    exit 1
fi

# The kernel drops the flock when this process exits; there is nothing to
# clean up. Exit 0 on a signal so a session shutdown is not a unit failure.
trap 'exit 0' INT TERM

echo "Starting Hyprland event listener (PID: $$)"

# Check Hyprland is running
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

# Set XWayland primary on startup
if [[ -x "$XWAYLAND_PRIMARY_SCRIPT" ]]; then
    (sleep 2 && "$XWAYLAND_PRIMARY_SCRIPT") &
fi

# Listen for Hyprland events
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
            # A monitor that re-appears during locked blanking relit itself
            # for ~6 min/cycle (issue #51): deep-sleeping panels drop their
            # hotplug line after DPMS-off and re-add as if freshly plugged.
            # blank-guard re-blanks only when the lock holds AND another
            # output is already dark - a plug at the lit lock screen stays
            # lit. sleep 2: let the re-add settle (mode set, profile apply)
            # before deciding; the v2 event carries "id,name,desc".
            name="${line#*>>}"; name="${name%%,*}"
            case "$line" in monitoraddedv2*) name=$(printf '%s' "${line#*>>}" | cut -d, -f2);; esac
            (sleep 2 && "@LIBEXECDIR@/blank-guard.sh" "$name") &
            ;;
        monitorremoved\>\>*)
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Monitor change: $line"
            if [[ -x "$XWAYLAND_PRIMARY_SCRIPT" ]]; then
                (sleep 1 && "$XWAYLAND_PRIMARY_SCRIPT") &
            fi
            ;;
    esac
done
