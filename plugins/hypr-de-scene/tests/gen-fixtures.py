#!/usr/bin/env python3
import importlib.util
import sys

OUTPUTS = (
    ("3440x1440", 3440, 1440, 0, 1.0),
    ("3840x2160 rotated at 1.5", 3840, 2160, 1, 1.5),
    ("1920x1080", 1920, 1080, 0, 1.0),
) + tuple((f"1366x768 transform {t}", 1366, 768, t, 1.0) for t in range(8))
REFS = (1440, 0)


def load(path):
    spec = importlib.util.spec_from_file_location("scene", path)
    scene = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scene)
    return scene


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: gen-fixtures.py /path/to/desktop-boot/lib/scene.py")
    scene = load(sys.argv[1])
    for ref in REFS:
        for name, w, h, transform, scale in OUTPUTS:
            tw, th = (h, w) if transform % 2 else (w, h)
            g = scene.geometry(tw, th, ref)
            print(f'{{"{name}", {{{w}, {h}}}, {transform}, {scale}, {ref}, '
                  f'{{{tw}, {th}}}, {{{g["logo_x"]}, {g["logo_y"]}, {g["logo"]}, {g["logo"]}}}}},')


if __name__ == "__main__":
    main()
