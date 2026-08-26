#!/usr/bin/env python3
import json
import subprocess
import sys

ICON_DEFAULT = "🎜"
ICON_SPOTIFY = ""

players = [
    "spotify",
    "mpd",
    "chromium",
    "firefox",
]


def run(*args):
    """Run a command as argv. Never a shell: `player` comes from
    `playerctl -l`, i.e. from whatever registered an MPRIS name, and an
    f-string into `sh -c` would make that name a command line."""
    try:
        return subprocess.check_output(args, stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return ""


def get_active_player():
    names = run("playerctl", "-l").splitlines()
    for candidate in players:
        if any(candidate in n for n in names):
            return candidate
    return names[0] if names else ""


def now_playing():
    player = get_active_player()
    if not player:
        return {"text": "", "alt": "", "tooltip": "", "class": "", "percentage": 0}

    artist = run("playerctl", "-p", player, "metadata", "artist")
    title = run("playerctl", "-p", player, "metadata", "title")
    status = run("playerctl", "-p", player, "status").lower()

    icon = ICON_SPOTIFY if "spotify" in player else ICON_DEFAULT
    state_icon = "" if status == "playing" else "" if status == "paused" else ""

    text = f"{title} - {artist} {state_icon}".strip()
    tooltip = f"{player}: {artist} - {title}".strip()

    return {
        "text": text[:60],
        "alt": player,
        "tooltip": tooltip,
        "class": status,
    }


def emit(data, last):
    """Print `data` unless it is what we printed last. Returns the new last.

    A closed pipe is waybar going away, not an error: exit quietly rather
    than dumping a BrokenPipeError traceback into its stderr.
    """
    line = json.dumps(data)
    if line == last:
        return last
    try:
        print(line, flush=True)
    except BrokenPipeError:
        sys.exit(0)
    return line


def follow():
    """Emit one line per actual change, and nothing in between.

    Waybar used to run this every 2 seconds behind an `exec-if` that
    itself forked a shell, `timeout`, `playerctl` and `grep` -- about four
    processes every two seconds, for ever, whether or not anything was
    playing. The state only changes when a player says so, and MPRIS says
    so: `playerctl --follow` subscribes to PropertiesChanged on
    org.mpris.MediaPlayer2.Player and blocks until something moves.

    It is used purely as a change trigger, not as the data source, so the
    player-preference order above still decides what is shown. Dedupe is on
    the rendered output, not the trigger: players emit metadata events far
    more often than the bar changes (a stopped chromium emitted three in
    five seconds during testing), and waybar only cares when the line it
    would draw is different.
    """
    last = None
    last = emit(now_playing(), last)
    # -F blocks until a property changes; the format keeps the trigger
    # cheap and stable (position is deliberately not in it).
    proc = subprocess.Popen(
        ["playerctl", "--follow", "-f", "{{status}}|{{playerName}}|{{artist}}|{{title}}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if proc.stdout is None:
        return
    for _trigger in proc.stdout:
        last = emit(now_playing(), last)


if __name__ == "__main__":
    if "--follow" in sys.argv[1:]:
        follow()
    else:
        print(json.dumps(now_playing()))
