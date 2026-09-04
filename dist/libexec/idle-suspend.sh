#!/bin/bash
# hypridle -> hyprstate idle-suspend bridge. Requesting is ALL this script
# may ever do: hyprstate owns grace, lock proof, cancellation and the
# Suspend() call (see hypridle.conf and desktop-commons secure-suspend-v0).
# A missing hyprstate is a soft no-op -- a session without the daemon
# simply never idle-suspends, which beats an error every idle period.
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
command -v hyprstate >/dev/null 2>&1 || exit 0
case "${1:-}" in
    --cancel) exec hyprstate suspend cancel ;;
    *)        exec hyprstate suspend request ;;
esac
