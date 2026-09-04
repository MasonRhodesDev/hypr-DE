#!/bin/sh
# hypridle condition_cmd for the two lock-gated listeners in
# hypr/hypridle.conf (the 30 s blanker and the 900 s idle-suspend request).
# Exit 0 exactly when the compositor holds the session lock.
#
# The compositor lock, not logind's LockedHint: it is the property the
# invariant is about -- a lock surface is covering the outputs -- and it is
# immune to two things the hint is not (hypridle runs in app.slice, where
# `loginctl show-session self` cannot resolve; and a hint can outlive the
# locker that set it). A stale "locked" must never authorise a blank over a
# live desktop; a failed lock never holds the compositor lock, so no marker
# check is needed here.
#
# No keep-awake check, deliberately (decided model, 2026-09-04): a claim --
# app inhibitor or the user's toggle, indistinguishable -- governs only the
# UNLOCKED machine, where it prevents the idle lock. Once locked, nothing
# is consulted again: the screen blanks and the suspend marches. The old
# toggle re-admission that kept a locked screen lit is gone with it.
#
# Bounded: hypridle runs condition_cmd synchronously (CProcess::runSync
# waits with no deadline of its own) on the single loop that also drives
# DPMS, the idle lock, unlock and sleep inhibits -- so anything that hangs
# here freezes the session's whole idle machinery. An unanswered compositor
# means "not locked", so no blank and no suspend request.
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
[ "$(timeout 2 hyprctl locked 2>/dev/null)" = true ] || exit 1
exit 0
