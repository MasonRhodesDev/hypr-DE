#!/bin/bash
# Ladder-entry gate: condition_cmd for the 180 s idle-lock listener in
# hypr/hypridle.conf. Exit 0 only when NO keep-awake claim is held, so the
# warn/blur (which IS ladder entry, decided model 2026-09-04) never starts
# under a live claim.
#
# STATELESS BY DESIGN. hypridle's own ScreenSaver ledger (still honored via
# the listener's ignore_inhibit=false) is wiped by a hypridle restart:
# clients never re-register, so a package upgrade mid-game silently dropped
# Steam's "Playing a game" claim and the blur fired over a live game
# (2026-09-03 incident #2). Every source here is re-derived at fire time
# and survives any restart. On a claim, the holder is printed (one line,
# source:name) for diagnosis; hypridle ignores stdout.
#
# Bounded everywhere: this runs on hypridle's single synchronous loop
# (CProcess::runSync has no deadline of its own), so a hang here freezes
# the session's whole idle machinery. Every probe carries timeout 2 and a
# failure reads as "no claim from this source".
PATH=/usr/local/bin:/usr/bin:/bin; export PATH

# 1) Wayland surface claims - what the compositor itself can see.
holder=$(timeout 2 hyprctl -j clients 2>/dev/null \
    | timeout 2 jq -r '[.[] | select(.inhibitingIdle == true) | .class] | first // empty' 2>/dev/null)
[ -n "$holder" ] && { printf 'wayland:%s\n' "$holder"; exit 1; }

# 2) The user's deliberate toggle.
[ "$(timeout 2 logind-idle-control status 2>/dev/null)" = 1 ] && { echo toggle; exit 1; }

# 3) logind idle-block inhibitors (systemd-inhibit --what=idle route).
if timeout 2 systemd-inhibit --list --no-pager 2>/dev/null \
    | awk '$0 ~ /idle/ && $0 ~ /block/ { found = 1 } END { exit !found }'; then
    echo logind-block; exit 1
fi

# 4) A running game. Most games raise no Wayland inhibitor at all
# (overwatch.exe: inhibitingIdle=false) - their only claim is Steam's
# overlay ScreenSaver inhibit, exactly the one a hypridle restart destroys.
# The overlay process is that claim's restart-proof shadow; gamescope
# likewise marks a game session.
timeout 2 pgrep -x gameoverlayui >/dev/null 2>&1 && { echo game:steam-overlay; exit 1; }
timeout 2 pgrep -x gamescope >/dev/null 2>&1 && { echo game:gamescope; exit 1; }

exit 0
