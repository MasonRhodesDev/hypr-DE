#!/bin/sh
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
readded="${1:-}"

"@LIBEXECDIR@/session-locked.sh" || exit 0

timeout 2 hyprctl -j monitors 2>/dev/null | jq -e --arg self "$readded" '
    any(.[]; .disabled == false and .dpmsStatus == false and .name != $self)
' >/dev/null || exit 0

exec "@LIBEXECDIR@/dpms-off-if-locked.sh"
