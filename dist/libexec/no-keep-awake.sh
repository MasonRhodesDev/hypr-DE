#!/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin; export PATH

holder=$(timeout 2 hyprctl -j clients 2>/dev/null \
    | timeout 2 jq -r '[.[] | select(.inhibitingIdle == true) | .class] | first // empty' 2>/dev/null)
[ -n "$holder" ] && { printf 'wayland:%s\n' "$holder"; exit 1; }

[ "$(timeout 2 logind-idle-control status 2>/dev/null)" = 1 ] && { echo toggle; exit 1; }

if timeout 2 systemd-inhibit --list --no-pager 2>/dev/null \
    | awk '$0 ~ /idle/ && $0 ~ /block/ { found = 1 } END { exit !found }'; then
    echo logind-block; exit 1
fi

timeout 2 pgrep -x gameoverlayui >/dev/null 2>&1 && { echo game:steam-overlay; exit 1; }
timeout 2 pgrep -x gamescope >/dev/null 2>&1 && { echo game:gamescope; exit 1; }

exit 0
