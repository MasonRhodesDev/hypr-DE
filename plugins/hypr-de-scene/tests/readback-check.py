#!/usr/bin/env python3
import glob
import importlib.util
import json
import os
import re
import sys

from PIL import Image, ImageChops

DREW = re.compile(r"scene: drew (\S+) before its commit, mode (\d+)x(\d+) transform (\d+) ")


def load(path):
    spec = importlib.util.spec_from_file_location("scene", path)
    scene = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scene)
    return scene


def to_buffer(box, transform, mode_w, mode_h):
    x0, y0, x1, y1 = box
    if transform == 0:
        return box
    if transform == 1:
        return (y0, mode_h - x1, y1, mode_h - x0)
    if transform == 2:
        return (mode_w - x1, mode_h - y1, mode_w - x0, mode_h - y0)
    if transform == 3:
        return (mode_w - y1, x0, mode_w - y0, x1)
    raise SystemExit(f"transform {transform} is not covered by this check")


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: readback-check.py OUT_DIR DATA_DIR /path/to/desktop-boot/lib/scene.py")
    out, data, scene = sys.argv[1], sys.argv[2], load(sys.argv[3])
    with open(os.path.join(data, "scene.json")) as f:
        spec = json.load(f)
    ref = spec.get("ref_short_side") or 0
    bg = scene.hexrgb(spec["palette"]["bg"])
    logo = Image.open(os.path.join(data, "logo.png")).convert("RGBA")
    visible = logo.getchannel("A").getbbox()

    with open(os.path.join(out, "dumps", "log")) as f:
        drawn = {m.group(1): tuple(int(v) for v in m.groups()[1:]) for m in map(DREW.search, f) if m}
    if not drawn:
        sys.exit("FAIL the plugin drew no first frame")

    fail = 0

    def check(ok, what):
        nonlocal fail
        print(("ok   " if ok else "FAIL ") + what)
        fail |= not ok

    for name, (mode_w, mode_h, transform) in sorted(drawn.items()):
        dumps = sorted(glob.glob(os.path.join(out, "dumps", f"{name}-*-*.ppm")),
                       key=lambda p: int(os.path.basename(p).split("-")[-2]))
        first = next((p for p in dumps if p.endswith("-first.ppm")), None)
        check(first is not None and dumps and dumps[0] == first, f"{name}: the first buffer it committed was drawn by the plugin")
        if first is None:
            continue
        im = Image.open(first).convert("RGB")
        check(im.size == (mode_w, mode_h), f"{name}: first frame is {mode_w}x{mode_h}")

        tw, th = (mode_h, mode_w) if transform % 2 else (mode_w, mode_h)
        g = scene.geometry(tw, th, ref)
        k = g["logo"] / logo.width
        want = to_buffer((g["logo_x"] + visible[0] * k, g["logo_y"] + visible[1] * k,
                          g["logo_x"] + visible[2] * k, g["logo_y"] + visible[3] * k), transform, mode_w, mode_h)
        got = ImageChops.difference(im, Image.new("RGB", im.size, bg)).getbbox()
        near = got is not None and all(abs(a - b) <= 1.5 for a, b in zip(got, want))
        check(near, f"{name}: logo covers {got}, scene.py puts it at {tuple(round(v, 1) for v in want)}")
        check(im.getpixel((0, 0)) == bg and im.getpixel((mode_w - 1, mode_h - 1)) == bg, f"{name}: ground is #%02x%02x%02x" % bg)

        same = [p for p in dumps if p.endswith("-pass.ppm") and Image.open(p).size == im.size]
        with open(first, "rb") as f:
            want_bytes = f.read()
        differ = []
        for p in same:
            with open(p, "rb") as f:
                if f.read() != want_bytes:
                    differ.append(os.path.basename(p))
        check(same and not differ, f"{name}: {len(same)} frames Hyprland rendered next are byte for byte the first frame"
              + (f", except {' '.join(differ)}" if differ else ""))

    sys.exit(fail)


if __name__ == "__main__":
    main()
