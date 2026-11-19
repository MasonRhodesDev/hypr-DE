#!/usr/bin/env python3
import glob
import importlib.util
import json
import os
import re
import sys

import cairo
from PIL import Image, ImageChops

DREW = re.compile(r"scene: drew (\S+) before its commit, mode (\d+)x(\d+) transform (\d+) ")

TO_BUFFER = {
    0: None,
    1: Image.Transpose.ROTATE_90,
    2: Image.Transpose.ROTATE_180,
    3: Image.Transpose.ROTATE_270,
    4: Image.Transpose.FLIP_LEFT_RIGHT,
    5: Image.Transpose.TRANSPOSE,
    6: Image.Transpose.FLIP_TOP_BOTTOM,
    7: Image.Transpose.TRANSVERSE,
}


def load(path):
    spec = importlib.util.spec_from_file_location("scene", path)
    scene = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scene)
    return scene


def sprite(png, size):
    source = cairo.ImageSurface.create_from_png(png)
    out = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    cr = cairo.Context(out)
    cr.scale(size / source.get_width(), size / source.get_height())
    cr.set_source_surface(source, 0, 0)
    cr.get_source().set_filter(cairo.FILTER_BEST)
    cr.paint()
    out.flush()
    return Image.frombuffer("RGBA", (size, size), bytes(out.get_data()), "raw", "BGRA", out.get_stride(), 1)


def over(premultiplied, bg):
    r, g, b, a = premultiplied.split()
    keep = a.point([255 - v for v in range(256)])
    return Image.merge("RGB", [
        ImageChops.add(c, keep.point([(ground * v * 2 + 255) // 510 for v in range(256)]))
        for c, ground in zip((r, g, b), bg)
    ])


def expected(scene, png, bg, ref, mode_w, mode_h, transform):
    tw, th = (mode_h, mode_w) if transform % 2 else (mode_w, mode_h)
    g = scene.geometry(tw, th, ref)
    logo = sprite(png, g["logo"])
    frame = Image.new("RGB", (tw, th), bg)
    frame.paste(over(logo, bg), (g["logo_x"], g["logo_y"]))
    blended = Image.new("L", (tw, th), 0)
    blended.paste(logo.getchannel("A").point([255 if 0 < v < 255 else 0 for v in range(256)]), (g["logo_x"], g["logo_y"]))
    if TO_BUFFER[transform] is not None:
        frame, blended = frame.transpose(TO_BUFFER[transform]), blended.transpose(TO_BUFFER[transform])
    return frame, blended, g


def worst(image):
    return max(high for _, high in image.getextrema())


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: readback-check.py OUT_DIR DATA_DIR /path/to/desktop-boot/lib/scene.py")
    out, data, scene = sys.argv[1], sys.argv[2], load(sys.argv[3])
    with open(os.path.join(data, "scene.json")) as f:
        spec = json.load(f)
    ref = spec.get("ref_short_side") or 0
    bg = scene.hexrgb(spec["palette"]["bg"])
    png = os.path.join(data, "logo.png")

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

        want, blended, g = expected(scene, png, bg, ref, mode_w, mode_h, transform)
        off = ImageChops.difference(im, want)
        solid = worst(Image.composite(Image.new("RGB", off.size), off, blended))
        check(solid == 0 and worst(off) <= 1,
              f"{name}: transform {transform}, first frame is the ground with the {g['logo']}px logo at {g['logo_x']},{g['logo_y']}, as scene.py places it: "
              f"every opaque and ground pixel is exact, and the {blended.histogram()[255]} the GPU blends are within 1 of 255"
              + ("" if solid == 0 and worst(off) <= 1 else f", but it differs inside {off.getbbox()} by up to {worst(off)} of 255, {solid} where nothing is blended"))

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
