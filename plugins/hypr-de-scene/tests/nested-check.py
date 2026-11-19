#!/usr/bin/env python3
"""Checks one readiness case run by nested-readback.sh against the scene's journal lines,
its readbacks, the host's screenshots and its record from hyprctl scene."""
import json
import os
import re
import sys

from PIL import Image

GROUND = (0x0B, 0x0D, 0x10)
DESKTOP = (0x20, 0x30, 0x40)
WALLPAPER = (0xFF, 0x80, 0x00)

LINE = {
    "first": re.compile(r"^scene: first frame on (\S+) fb \d+ at (\S+)"),
    "added": re.compile(r"^scene: output (\S+) added while covering at (\S+)"),
    "ready": re.compile(r"^scene: session ready at (\S+)"),
    "mapped": re.compile(r"^scene: layer (\S+) mapped on (\S+) at (\S+), (\d+) of (\d+) outputs"),
    "background": re.compile(r"^scene: background (ready|failed) on (\S+) at (\S+)"),
    "dropped": re.compile(r"^scene: holding input, first dropped (\S+) at (\S+)"),
    "fading": re.compile(r"^scene: fading at (\S+), reason (\S+), (\d+)ms after first frame, missing (.*), dropped (\d+) input events$"),
    "released": re.compile(r"^scene: released at (\S+), fade (\d+)ms"),
    "dumped": re.compile(r"^scene: dumped (\S+) at (\S+)"),
}

failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def share(image, color, tolerance=2):
    data = image.convert("RGB").resize((96, 54)).tobytes()
    pixels = [data[i : i + 3] for i in range(0, len(data), 3)]
    return sum(all(abs(a - b) <= tolerance for a, b in zip(p, color, strict=True)) for p in pixels) / len(pixels)


def record(out, name):
    try:
        with open(os.path.join(out, f"{name}.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: nested-check.py OUT_DIR CASE")
    out, case = sys.argv[1], sys.argv[2]

    events = []
    with open(os.path.join(out, "dumps", "log")) as f:
        for text in f:
            for kind, pattern in LINE.items():
                if m := pattern.match(text.rstrip("\n")):
                    events.append((kind, m.groups()))

    def all_of(kind):
        return [g for k, g in events if k == kind]

    def index(kind, test):
        return next((i for i, (k, g) in enumerate(events) if k == kind and test(g)), None)

    with open(os.path.join(out, "shots", "times")) as f:
        shots = [(os.path.join(out, "shots", name), float(at)) for name, at in (line.split() for line in f)]

    if case == "unload":
        with open(os.path.join(out, "dumps", "log")) as f:
            unloaded = [float(m.group(1)) for m in map(re.compile(r"^scene: released at (\S+), unload while covering").match, f) if m]
        check(len(unloaded) == 1 and not all_of("fading"), "unload: unloading while covering releases the scene at once, with no fade")
        after = [(p, at) for p, at in shots if unloaded and at >= unloaded[0] + 0.3]
        stuck = [os.path.basename(p) for p, at in after if share(Image.open(p), GROUND) >= 0.5]
        check(after and not stuck, f"unload: {len(after)} screenshots after the unload show the desktop"
              + (f", but {' '.join(stuck)} still show the scene" if stuck else ""))
        sys.exit(1 if failures else 0)

    fadings, released = all_of("fading"), all_of("released")
    check(len(fadings) == 1, f"{case}: the scene starts fading once ({len(fadings)})")
    check(len(released) == 1, f"{case}: the scene is released once ({len(released)})")
    if failures:
        sys.exit(1)
    fading_at, reason, after_first, missing, dropped = fadings[0]
    fading_at, after_first, dropped = float(fading_at), int(after_first), int(dropped)
    released_at = float(released[0][0])
    # reading back ten outputs, some at 4K, holds up Hyprland's loop during the readback case's fade
    longest = 0.6 if case == "readback" else 0.3
    check(0.18 <= released_at - fading_at <= longest, f"{case}: the fade takes 200 ms, {1000 * (released_at - fading_at):.0f} ms")

    first = [float(g[1]) for g in all_of("first")]
    first_at = min(first) if first else None
    final = record(out, "final")
    outputs = final["outputs"] if final else []
    check(final is not None and final["state"] == "released" and final["reason"] == reason,
          f"{case}: hyprctl scene reports the scene released by {reason}")

    # the host window starts small and black around it, so the scene is in full from the first shot that shows it
    start = next((at for p, at in shots if share(Image.open(p), GROUND) >= 0.9), None)
    covered = [(p, at) for p, at in shots if start is not None and start <= at <= fading_at]
    bare = [os.path.basename(p) for p, at in covered if share(Image.open(p), GROUND) < 0.9]
    instant = first_at is not None and fading_at - first_at < 0.3
    check((covered or instant) and not bare, f"{case}: every one of {len(covered)} screenshots from the first frame to the fade shows the scene"
          + (f", but {' '.join(bare)} do not" if bare else ""))
    shown = [(p, at) for p, at in shots if at >= released_at + 0.3]
    still = [os.path.basename(p) for p, at in shown if share(Image.open(p), GROUND) >= 0.5]
    check(shown and not still, f"{case}: {len(shown)} screenshots after release show the desktop"
          + (f", but {' '.join(still)} still show the scene" if still else ""))

    def readbacks(kind):
        found = {}
        for name in sorted(os.listdir(os.path.join(out, "dumps"))):
            if name.endswith(f"-{kind}.ppm"):
                output, number = name[: -len(f"-{kind}.ppm")].rsplit("-", 1)
                found.setdefault(output, []).append((int(number), os.path.join(out, "dumps", name)))
        return {k: [p for _, p in sorted(v)] for k, v in found.items()}

    def at_rest_with(color):
        after = readbacks("after")
        wrong, moving = [], []
        for output in outputs:
            frames = after.get(output, [])
            if not frames or share(Image.open(frames[0]), color, 1) < 0.99:
                wrong.append(output)
            if len(frames) < 2 or Image.open(frames[0]).tobytes() != Image.open(frames[1]).tobytes():
                moving.append(output)
        return wrong, moving

    def near(a, b, ms):
        return abs(a - b) <= ms / 1000

    if case == "N1":
        ready = all_of("ready")
        check(reason == "ready" and ready and near(fading_at, float(ready[0][0]), 50),
              f"N1: fading reason ready within 50 ms of session ready ({reason}, {1000 * (fading_at - float(ready[0][0])) if ready else 0:.0f} ms)")
    elif case == "N2":
        maps = [float(g[2]) for g in all_of("mapped") if g[0] == "wallpaper"]
        check(reason == "ready" and maps and fading_at >= max(maps) and near(fading_at, max(maps), 50),
              f"N2: fading reason ready within 50 ms of the last wallpaper map ({reason}, {1000 * (fading_at - max(maps)) if maps else 0:.0f} ms)")
        check(len(maps) >= len(outputs) == 4, f"N2: the wallpaper mapped on all {len(outputs)} outputs before the fade ({len(maps)} maps)")
        shown = [o for o, frames in readbacks("pass").items() if any(share(Image.open(p), WALLPAPER) > 0.01 for p in frames)]
        check(not shown, "N2: no readback while covering shows the wallpaper" + (f", but {' '.join(shown)} do" if shown else ""))
        wrong, moving = at_rest_with(WALLPAPER)
        check(not wrong, "N2: the first frame after release shows the wallpaper at full alpha" + (f", except on {' '.join(wrong)}" if wrong else ""))
        check(not moving, "N2: the next frame is the same, so nothing was still fading in" + (f", except on {' '.join(moving)}" if moving else ""))
    elif case == "N2b":
        ready = {g[1]: float(g[2]) for g in all_of("background") if g[0] == "ready"}
        check(reason == "ready" and set(ready) == set(outputs) and fading_at >= max(ready.values(), default=0),
              f"N2b: fading reason ready waits for Hyprland's wallpaper on every output ({reason}, ready on {len(ready)} of {len(outputs)})")
        after = readbacks("after")
        moving = [o for o in outputs if len(after.get(o, [])) < 2 or Image.open(after[o][0]).tobytes() != Image.open(after[o][1]).tobytes()]
        bare = [o for o in outputs if not after.get(o) or share(Image.open(after[o][0]), DESKTOP, 2) > 0.9]
        check(not bare, "N2b: the first frame after release shows Hyprland's wallpaper" + (f", but {' '.join(bare)} show the bare ground" if bare else ""))
        check(not moving, "N2b: the next frame is the same, so the wallpaper was at full alpha" + (f", except on {' '.join(moving)}" if moving else ""))
    elif case == "N3":
        check(reason == "quiet" and first_at is not None and 1450 <= after_first <= 1550,
              f"N3: fading reason quiet 1.5 s after the first frame ({reason}, {after_first} ms)")
    elif case == "N4":
        lost = [o for o in outputs if f"waybar on {o}" not in missing.split(", ")]
        check(reason == "timeout" and 4950 <= after_first <= 5050, f"N4: fading reason timeout at 5 s ({reason}, {after_first} ms)")
        check(len(outputs) == 4 and not lost, f"N4: missing names waybar on all {len(outputs)} outputs ({missing})")
    elif case == "N5":
        added = index("added", lambda g: g[0] == "HEADLESS-5")
        mapped = index("mapped", lambda g: g[0] == "wallpaper" and g[1] == "HEADLESS-5")
        fade = index("fading", bool)
        first_dumps = sorted(n for n in os.listdir(os.path.join(out, "dumps")) if n.startswith("HEADLESS-5-0-"))
        check(added is not None and "HEADLESS-5" in outputs, "N5: the output created during the hold joined it")
        check(first_dumps == ["HEADLESS-5-0-first.ppm"] and share(Image.open(os.path.join(out, "dumps", first_dumps[0])), GROUND) > 0.5,
              f"N5: its first readback is the scene ({' '.join(first_dumps) or 'none'})")
        check(reason == "ready" and mapped is not None and added < mapped < fade,
              f"N5: the wallpaper expectation waited for the new output before fading reason ready ({reason})")
    elif case == "N6":
        maps = [float(g[2]) for g in all_of("mapped") if g[0] == "wallpaper"]
        check(reason == "ready" and len(maps) == 1 and near(fading_at, maps[0] + 0.25, 50),
              f"N6: a layer on one output releases 250 ms after its map ({reason}, {1000 * (fading_at - maps[0]) if maps else 0:.0f} ms)")
    elif case == "N7":
        check(reason == "lock" and after_first < 4900, f"N7: a session lock releases the scene at once ({reason}, {after_first} ms)")
    elif case == "N8":
        held, after = record(out, "held"), record(out, "after")
        with open(os.path.join(out, "hyprctl.log")) as f:
            replies = f.read()
        check(reason == "manual", f"N8: hyprctl scene release fades with reason manual ({reason})")
        check(held is not None and len(held["expect"]) == 32 and "bad\"name" not in held["expect"] and "late" not in held["expect"],
              f"N8: the scene kept 32 expectations, refused the bad and the long names and the 33rd ({len(held['expect']) if held else 'no record'})")
        check(replies.count("error:") == 3 + 9, f"N8: each refused command was answered with an error ({replies.count('error:')})")
        check(after is not None and after["state"] in ("fading", "released") and "late" not in after["expect"], "N8: a command after release changes nothing")
    elif case == "N9":
        check(reason == "ready" and after_first <= 100, f"N9: without a service manager the scene fades on its first frames ({reason}, {after_first} ms)")
    elif case == "N10":
        typed, plain, chord = record(out, "typed"), record(out, "plain"), record(out, "chord")
        try:
            with open(os.path.join(out, "typed")) as f:
                text = f.read()
        except OSError:
            text = None
        check(typed is not None and typed["dropped"] >= 5, f"N10: the five keys typed under the scene were dropped ({typed['dropped'] if typed else 'no record'})")
        check(typed is not None and plain is not None and plain["dropped"] - typed["dropped"] == 1,
              f"N10: F2 alone was dropped ({plain['dropped'] - typed['dropped'] if typed and plain else '?'})")
        check(plain is not None and chord is not None and chord["dropped"] == plain["dropped"],
              f"N10: Ctrl+Alt+F2 was not dropped, so it reaches Hyprland's VT switch ({chord['dropped'] - plain['dropped'] if plain and chord else '?'})")
        # foot writes Ctrl+Alt+F2 as an escape sequence, since nested Hyprland has no VT to switch to
        check(text == "\x1b[1;7Qworld\n",
              f"N10: the window under the scene received only Ctrl+Alt+F2, and after release it received what was typed ({text!r})")
        check(dropped == (chord["dropped"] if chord else -1), f"N10: the fade reports the dropped count ({dropped})")
    elif case == "readback":
        pass
    else:
        check(False, f"no case {case}")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
