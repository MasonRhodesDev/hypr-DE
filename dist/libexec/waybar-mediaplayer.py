#!/usr/bin/env python3
"""waybar custom/media backend: a stream, not a poll.

waybar runs this once with no interval and reads stdout as a continuous
feed: every line is a fresh module state, and an empty line hides the
module. The feed comes from `playerctl --follow`, which blocks on the
session bus and prints only when the selected player's metadata or
playback status changes. Nothing here wakes up on a timer.

Before this, waybar ran `playerctl status` every 2 s as the module's
exec-if and, while something played, this script with three more
playerctl calls per tick: five short-lived processes every two seconds,
for the whole session, to notice a track change.
"""
import json
import signal
import subprocess
import sys
import time

# Priority order for the player the module follows. playerctl keeps this
# order; recency only breaks ties among players the list ranks equally,
# and %any admits every other MPRIS name at the lowest rank. This is the
# order the polling version used, so the bar shows the same player it did.
PLAYERS = "spotify,mpd,chromium,firefox,%any"

# One line per change, four fields. A tab cannot appear in a player name
# and is vanishingly rare in a title; a title that does carry one keeps it,
# since the split is capped at four fields. status is in the template on
# purpose: playerctl re-emits on playback-status changes only when the
# format names it, and play/pause is exactly what hides and shows the
# module.
FIELD_SEP = "\t"
FORMAT = FIELD_SEP.join(("{{playerName}}", "{{status}}", "{{artist}}", "{{title}}"))

# After playerctl exits (the bus went away, it crashed), wait this long
# before following again, doubling up to the cap. A bus that is really gone
# then costs one spawn a minute rather than a busy loop.
RETRY_DELAY = 5
RETRY_CAP = 60

# Nerd Font play/pause/stop (private-use codepoints, written as escapes so
# no editor can silently drop them).
STATE_ICON = {"playing": "\uf04b", "paused": "\uf04c", "stopped": "\uf04d"}

child = None


def follow_command():
    """argv, never a shell: player names and titles come from whatever
    registered an MPRIS name, and they only ever appear in playerctl's
    OUTPUT here, not on a command line."""
    return ["playerctl", "--player", PLAYERS, "--follow", "metadata", "--format", FORMAT]


def render(line):
    """One playerctl line -> the dict waybar shows, or None to hide the module.

    Hidden unless something is actually Playing: a paused track lingering
    in the middle of the bar is noise, and that is what the polling
    version's exec-if enforced."""
    if not line:
        return None
    parts = line.split(FIELD_SEP, 3)
    if len(parts) < 4:
        return None
    player, status, artist, title = parts
    status = status.strip().lower()
    if status != "playing":
        return None
    label = " - ".join(p for p in (title.strip(), artist.strip()) if p)
    text = f"{label} {STATE_ICON[status]}".strip()
    return {
        "text": text[:60],
        "alt": player,
        "tooltip": f"{player}: {artist} - {title}".strip(),
        "class": status,
    }


def emit(state):
    sys.stdout.write(("" if state is None else json.dumps(state)) + "\n")
    sys.stdout.flush()


def stream():
    """Follow playerctl until it exits. Returns its exit status, or None when
    playerctl is not installed at all."""
    global child
    try:
        child = subprocess.Popen(
            follow_command(), stdout=subprocess.PIPE, text=True, errors="replace"
        )
    except FileNotFoundError:
        return None
    last = object()
    with child:
        for line in child.stdout:
            state = render(line.rstrip("\n"))
            if state != last:
                emit(state)
                last = state
    return child.returncode


def stop(signum, frame):
    # waybar ends the stream with a signal; take playerctl down with us so
    # no follower outlives the bar.
    if child is not None and child.poll() is None:
        child.terminate()
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    # A closed stdout (waybar gone) ends this process quietly.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    delay = RETRY_DELAY
    while True:
        try:
            status = stream()
        except Exception as e:  # noqa: BLE001 - a bug must not kill the module for the session
            print(f"waybar-mediaplayer: {e!r}", file=sys.stderr)
            status = 1
        emit(None)  # whatever was showing is stale once the feed is gone
        if status is None:
            print("waybar-mediaplayer: playerctl not installed; nothing to follow", file=sys.stderr)
            return 0
        time.sleep(delay)
        delay = min(delay * 2, RETRY_CAP)


if __name__ == "__main__":
    sys.exit(main())
