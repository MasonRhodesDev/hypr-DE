#!/usr/bin/env python3
"""Print the user units deps.toml declares as required, one per line.

deps.toml is the source of truth for what hypr-DE pulls in; a `units` key on a
section says which user units that dependency must contribute. check-units.sh
asserts they are preset and validated by hypr-de-setup.
"""
import sys, tomllib

with open(sys.argv[1], "rb") as fh:
    data = tomllib.load(fh)

units = set()
for section in data.values():
    if isinstance(section, dict):
        units.update(section.get("units", []))
print("\n".join(sorted(units)))
