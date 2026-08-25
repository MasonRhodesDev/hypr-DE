#!/bin/sh
# on-timeout of the locked-screen blanking listener in hypr/hypridle.conf.
# Re-checks the compositor lock itself so the blank is safe even if the
# listener's condition_cmd were ever lost (an older hypridle drops unknown
# keys and would run on-timeout unconditionally): a DPMS-off must never land
# on an unlocked desktop. A failed lock never holds the compositor lock, so
# the lock-failed marker lock-cmd.sh maintains is implied by this check.
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
[ "$(hyprctl locked 2>/dev/null)" = true ] || exit 0
exec hyprctl dispatch "hl.dsp.dpms({ action = 'off' })"
