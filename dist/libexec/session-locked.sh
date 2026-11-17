#!/bin/sh
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
[ "$(timeout 2 hyprctl locked 2>/dev/null)" = true ] || exit 1
exit 0
