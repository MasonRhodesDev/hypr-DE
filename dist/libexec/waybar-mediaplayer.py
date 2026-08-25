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


if __name__ == "__main__":
    data = now_playing()
    print(json.dumps(data))
