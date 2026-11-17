#!/bin/bash

set -euo pipefail

if ! systemctl --user is-active waybar &>/dev/null; then
    echo "waybar service not active, skipping check"
    exit 0
fi

mapfile -t waybar_pids < <(pgrep -x waybar 2>/dev/null || true)

if [ ${#waybar_pids[@]} -eq 0 ]; then
    echo "No waybar processes found"
    exit 0
fi

has_zombie=false
for pid in "${waybar_pids[@]}"; do
    if [ -z "$pid" ]; then
        continue
    fi

    state=$(ps -p "$pid" -o state= 2>/dev/null | tr -d ' ' || echo "")
    stat=$(ps -p "$pid" -o stat= 2>/dev/null | tr -d ' ' || echo "")

    echo "waybar PID $pid: state=$state stat=$stat"

    if [[ "$state" =~ ^[ZXx] ]]; then
        echo "WARNING: waybar PID $pid is in bad state: $state (stat: $stat)"
        has_zombie=true

        if [ "$state" = "Z" ]; then
            parent_pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || echo "unknown")
            cmd=$(ps -p "$pid" -o cmd= 2>/dev/null || echo "unknown")
            etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ' || echo "unknown")
            echo "  Zombie process details:"
            echo "    Parent PID: $parent_pid"
            echo "    Command: $cmd"
            echo "    Elapsed time: $etime"

            if [ -r "/proc/$pid/cmdline" ]; then
                cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
                [ -n "$cmdline" ] && echo "    Cmdline: $cmdline"
            fi
        fi
    fi
done

if [ "$has_zombie" = true ]; then
    echo "Restarting waybar due to zombie/dead processes..."
    systemctl --user restart waybar
    echo "waybar restarted successfully"
    exit 0
fi

if command -v hyprctl &>/dev/null; then
    if timeout 3 hyprctl layers 2>&1 | grep -q "namespace: waybar"; then
        echo "waybar health check passed (process healthy, layers visible)"
    else
        echo "WARNING: waybar process running but no layers detected"
        echo "Restarting waybar..."
        systemctl --user restart waybar
        sleep 5
        if timeout 3 hyprctl layers 2>&1 | grep -q "namespace: waybar"; then
            echo "waybar restarted successfully, layers now visible"
        else
            echo "WARNING: waybar restarted but still no layers"
        fi
    fi
else
    echo "waybar health check passed (hyprctl not available, skipping layer check)"
fi
