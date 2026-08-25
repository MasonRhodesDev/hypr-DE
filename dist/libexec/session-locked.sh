#!/bin/sh
# hypridle condition_cmd for the locked-screen blanking listener in
# hypr/hypridle.conf: exit 0 only while the compositor holds the session
# lock. This is the property the invariant is about -- a lock surface is
# covering the outputs -- and it is immune to two things logind's
# LockedHint is not: hint resolution (hypridle runs in app.slice, so
# `loginctl show-session self` fails there) and a hint left set by a locker
# that died (hyprstate aborts suspend on exactly that). A stale "locked"
# must never authorise a blank over a live desktop; a failed lock never
# holds the compositor lock, so no marker check is needed here.
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
[ "$(hyprctl locked 2>/dev/null)" = true ]
