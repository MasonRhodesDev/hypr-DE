#!/usr/bin/env python3
import json
import signal
import subprocess
import sys
import time

PLAYERS = "spotify,mpd,chromium,firefox,%any"

FIELD_SEP = "\t"
FORMAT = FIELD_SEP.join(("{{playerName}}", "{{status}}", "{{artist}}", "{{title}}"))

RETRY_DELAY = 5
RETRY_CAP = 60

STATE_ICON = {"playing": "\uf04b", "paused": "\uf04c", "stopped": "\uf04d"}

child = None


def follow_command():
    return ["playerctl", "--player", PLAYERS, "--follow", "metadata", "--format", FORMAT]


def render(line):
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
    if child is not None and child.poll() is None:
        child.terminate()
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    delay = RETRY_DELAY
    while True:
        try:
            status = stream()
        except Exception as e:  # noqa: BLE001 - a bug must not kill the module for the session
            print(f"waybar-mediaplayer: {e!r}", file=sys.stderr)
            status = 1
        emit(None)
        if status is None:
            print("waybar-mediaplayer: playerctl not installed; nothing to follow", file=sys.stderr)
            return 0
        time.sleep(delay)
        delay = min(delay * 2, RETRY_CAP)


if __name__ == "__main__":
    sys.exit(main())
