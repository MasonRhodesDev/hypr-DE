#!/bin/sh
# hypridle DPMS-off listener. Skip while locked: Aquamarine restoreAfterVT
# releases CRTCs from disabled outputs and never modesets them, so VT1
# comes back blank with the lock still held.
hint=$(loginctl show-session self -p LockedHint --value 2>/dev/null || true)
[ "$hint" = yes ] && exit 0
exec hyprctl dispatch "hl.dsp.dpms({ action = 'off' })"
