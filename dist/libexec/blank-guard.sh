#!/bin/sh
# Re-blank an output that re-appeared during locked blanking.
#
# Some monitors deep-sleep on DPMS-off, drop their hotplug line ~20 s later,
# and re-announce - and a re-added output is indistinguishable from the user
# plugging one in, so it comes back lit and stays lit until the blanking
# listener's next timeout (~6 minutes observed, five cycles in one morning,
# issue #51). Called by hyprland-configreload-listener on monitoradded.
#
# Two conditions, both load-bearing:
#   1. session-locked.sh must pass - the compositor holds the lock and the
#      user's idle toggle is not held. Never blank an unlocked desktop
#      (desktop-dpms-arbitration-v0: dark outputs over a live session are
#      indistinguishable from a locked screen).
#   2. Some OTHER enabled output must already be DPMS-off. A monitor
#      genuinely plugged in while the user types at the LIT lock screen
#      must not blank the session under their hands; only when the blank is
#      demonstrably active does a new output join it.
#
# The blank itself is dpms-off-if-locked.sh - the same lock-gated argv the
# listener's timeout uses, so this adds no new OFF producer, only a new
# trigger for the existing one. Argument (the re-added output name) is used
# only to exclude it from condition 2.
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
readded="${1:-}"

"@LIBEXECDIR@/session-locked.sh" || exit 0

# Bounded like every hyprctl call in this family: an unanswered compositor
# means "do nothing", never "wait".
timeout 2 hyprctl -j monitors 2>/dev/null | jq -e --arg self "$readded" '
    any(.[]; .disabled == false and .dpmsStatus == false and .name != $self)
' >/dev/null || exit 0

exec "@LIBEXECDIR@/dpms-off-if-locked.sh"
