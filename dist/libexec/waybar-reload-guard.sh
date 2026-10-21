#!/bin/bash
# ExecCondition for waybar-reload.service: exit 0 to proceed with the restart,
# exit 1 to skip it cleanly (the unit stays inactive, not failed).
#
# hypr-de-prime-theme renders waybar.css during session start, before the bar
# exists, so the stylesheet the first waybar reads is already current. That
# write still trips waybar-reload.path, and the queued restart would kill the
# bar mid-init and start it a second time. A stylesheet change that lands while
# waybar is starting, or within a few seconds of it becoming active, is
# therefore already applied and needs no restart. Later edits (theme
# hot-reload) are unaffected.

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
