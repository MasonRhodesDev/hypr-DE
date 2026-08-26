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
# The listener sets ignore_inhibit, which drops hypridle's whole inhibitor
# accounting: the user's deliberate toggle, the freedesktop ScreenSaver
# D-Bus API, and the Wayland surface inhibitors that video players,
# browsers and call apps set on their own with no user-visible control. A
# locked screen must not be held lit all night by a paused video nobody
# remembers.
#
# This script used to re-admit the deliberate toggle. It no longer does,
# because "locked while the toggle is held" turns out to be unreachable:
# the 180 s idle-lock listener obeys inhibitors, so a held toggle prevents
# the lock rather than surviving it; every deliberate path into a lock
# (lock-cmd.sh manual and --sleep) releases the toggle first; and once
# locked the toggle cannot be reached at all -- the lock surface covers
# waybar's tray and vigil's theme contract exposes only clock,
# user_selector, password, status and power. The one case where the check
# could still have fired -- the release call failing -- is exactly the case
# where it did the wrong thing, keeping the screen lit after a deliberate
# lock. Checking it also put a subprocess on hypridle's synchronous
# condition path, which its own event loop blocks on.
# The call is bounded. hypridle runs condition_cmd synchronously
# (CProcess::runSync waits for the child to exit, with no deadline of its
# own) on the single loop that also drives DPMS, the idle lock, unlock and
# sleep inhibits -- so anything that hangs here freezes the session's whole
# idle machinery, not just this check. The failure direction is safe: an
# unanswered compositor reads as "not locked", so nothing blanks.
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
[ "$(timeout 2 hyprctl locked 2>/dev/null)" = true ] || exit 1
exit 0
