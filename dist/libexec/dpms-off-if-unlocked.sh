#!/bin/sh
# hypridle DPMS-off listener for the unlocked idle path. Skip while locked:
# the input-idle listener in hypridle.conf (session-locked.sh) owns every
# locked-screen blank, and one blanker per state beats two racing. The
# Aquamarine restoreAfterVT hazard -- CRTCs of disabled outputs never
# modeset again, VT1 returns blank with the lock held -- is a known,
# untested hazard of any locked blank; Hyprland's key/mouse DPMS wake and
# hyprstate's cursor-gated stuck-DPMS repair are the only mitigations.
# Same authority as the locked listener: the compositor's own lock, never
# logind's LockedHint. The two must agree or a state falls between them --
# a hint left set by a dead locker made this script defer to a listener
# whose condition (correctly) said unlocked, and the idle desktop stayed
# lit for ever. (`loginctl show-session self` never resolved from
# hypridle's cgroup either, so this guard has never actually held.)
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
[ "$(hyprctl locked 2>/dev/null)" = true ] && exit 0

# Also skip when a lock attempt failed (lock-cmd.sh leaves this marker and
# HYPR_DE_LOCK_FAILSAFE=warn kept the session). Blanking here is what turns a
# failed lock into a security hole: dark outputs are indistinguishable from a
# locked screen, so the user walks away from a live desktop. Leave them lit --
# an obviously unlocked screen is the honest, safer failure.
runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
[ -e "$runtime_dir/hypr-de-lock-failed" ] && exit 0

exec hyprctl dispatch "hl.dsp.dpms({ action = 'off' })"
