#!/usr/bin/env python3
import sys, tomllib

with open(sys.argv[1], "rb") as fh:
    data = tomllib.load(fh)

units = set()
for section in data.values():
    if isinstance(section, dict):
        units.update(section.get("units", []))
print("\n".join(sorted(units)))
