#!/bin/sh
# hypridle condition_cmd for the locked-screen blanking listener in
# hypr/hypridle.conf. Exit 0 only when the screen may go dark: the
# compositor holds the session lock, and the user has not asked the session
# to stay awake.
#
# The compositor lock, not logind's LockedHint: it is the property the
# invariant is about -- a lock surface is covering the outputs -- and it is
# immune to two things the hint is not (hypridle runs in app.slice, where
# `loginctl show-session self` cannot resolve; and a hint can outlive the
# locker that set it). A stale "locked" must never authorise a blank over a
# live desktop; a failed lock never holds the compositor lock, so no marker
# check is needed here.
#
# The idle inhibitor is checked here rather than left to hypridle because
# the listener sets ignore_inhibit: hypridle's accounting covers three
# sources -- the user's deliberate toggle, the freedesktop ScreenSaver
# D-Bus API, and Wayland surface inhibitors that video players, browsers
# and call apps set on their own with no user-visible control. A locked
# screen should not be held lit all night by a paused video nobody
# remembers, so the listener ignores that accounting wholesale and this
# re-admits the single source the user actually chose. No toggle installed
# means nothing was chosen.
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
[ "$(hyprctl locked 2>/dev/null)" = true ] || exit 1
if command -v logind-idle-control >/dev/null 2>&1; then
    [ "$(logind-idle-control status 2>/dev/null)" = 1 ] && exit 1
fi
exit 0
