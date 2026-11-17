#!/bin/bash

set -u

grace_s=${HYPR_DE_WAYBAR_RELOAD_GRACE:-8}

state=$(systemctl --user show waybar.service -p ActiveState --value 2>/dev/null || true)
if [ "$state" = "activating" ]; then
    exit 1
fi
[ "$state" = "active" ] || exit 0

entered_us=$(systemctl --user show waybar.service -p ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)
case "$entered_us" in
    ''|*[!0-9]*) exit 0 ;;
esac
now_us=$(awk '{ printf "%d", $1 * 1000000 }' /proc/uptime)
age_s=$(( (now_us - entered_us) / 1000000 ))
if [ "$age_s" -lt "$grace_s" ]; then
    exit 1
fi
exit 0
