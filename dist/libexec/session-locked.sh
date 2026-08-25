#!/bin/sh
# hypridle condition_cmd for the locked-screen blanking listener in
# hypr/hypridle.conf. Exit 0 only while logind reports this session locked --
# the same LockedHint lock-cmd.sh and dpms-off-if-unlocked.sh trust -- so an
# input-idle timeout blanks locked outputs and defers (condition_retry) for
# everything else. A failed lock never sets the hint, so the fail-open guard
# lock-cmd.sh maintains needs no marker check here.
hint=$(loginctl show-session self -p LockedHint --value 2>/dev/null || true)
[ "$hint" = yes ]
