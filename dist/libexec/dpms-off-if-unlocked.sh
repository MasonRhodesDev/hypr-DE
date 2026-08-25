#!/bin/sh
# hypridle DPMS-off listener for the unlocked idle path. Skip while locked:
# the input-idle listener in hypridle.conf (session-locked.sh) owns every
# locked-screen blank, and one blanker per state beats two racing. The
# Aquamarine restoreAfterVT hazard -- CRTCs of disabled outputs never
# modeset again, VT1 returns blank with the lock held -- is a known,
# untested hazard of any locked blank; Hyprland's key/mouse DPMS wake and
# hyprstate's cursor-gated stuck-DPMS repair are the only mitigations.
# Not session `self`: from hypridle's cgroup (app.slice) logind cannot map
# the caller to a session, so `self` fails and the guard silently passed --
# this listener blanked locked sessions for as long as it existed.
hint=$(loginctl show-session "${XDG_SESSION_ID:-auto}" -p LockedHint --value 2>/dev/null || true)
[ "$hint" = yes ] && exit 0

# Also skip when a lock attempt failed (lock-cmd.sh leaves this marker and
# HYPR_DE_LOCK_FAILSAFE=warn kept the session). Blanking here is what turns a
# failed lock into a security hole: dark outputs are indistinguishable from a
# locked screen, so the user walks away from a live desktop. Leave them lit --
# an obviously unlocked screen is the honest, safer failure.
runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
[ -e "$runtime_dir/hypr-de-lock-failed" ] && exit 0

exec hyprctl dispatch "hl.dsp.dpms({ action = 'off' })"
