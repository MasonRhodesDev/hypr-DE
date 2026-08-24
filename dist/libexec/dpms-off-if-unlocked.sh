#!/bin/sh
# hypridle DPMS-off listener. Skip while locked: Aquamarine restoreAfterVT
# releases CRTCs from disabled outputs and never modesets them, so VT1
# comes back blank with the lock still held.
hint=$(loginctl show-session self -p LockedHint --value 2>/dev/null || true)
[ "$hint" = yes ] && exit 0

# Also skip when a lock attempt failed (lock-cmd.sh leaves this marker and
# HYPR_DE_LOCK_FAILSAFE=warn kept the session). Blanking here is what turns a
# failed lock into a security hole: dark outputs are indistinguishable from a
# locked screen, so the user walks away from a live desktop. Leave them lit --
# an obviously unlocked screen is the honest, safer failure.
runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
[ -e "$runtime_dir/hypr-de-lock-failed" ] && exit 0

exec hyprctl dispatch "hl.dsp.dpms({ action = 'off' })"
