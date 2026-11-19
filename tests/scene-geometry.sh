#!/bin/bash
[ -e /run/tripwire/hits ] || { [ "${HYPR_DE_SEALED-}" = build-root ] && [ ! -e /run/systemd/private ]; } || exec "$(dirname -- "$0")/run" "$0"
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
src=$root/plugins/hypr-de-scene
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cxx=${CXX:-c++}
command -v "$cxx" >/dev/null || { echo "FAIL no C++ compiler ($cxx) to build the scene geometry test"; exit 1; }

"$cxx" -std=c++23 -Wall -Wextra -Werror -ffp-contract=off -o "$work/geometry" \
    "$src/tests/geometry.cpp" "$src/src/Geometry.cpp" "$src/src/Spec.cpp" \
    || { echo "FAIL the scene geometry test does not compile"; exit 1; }
"$work/geometry" || exit 1

scene_py=${DESKTOP_BOOT_LIB:-/usr/lib/desktop-boot/lib}/scene.py
if [ -r "$scene_py" ] && command -v python3 >/dev/null; then
    if python3 "$src/tests/gen-fixtures.py" "$scene_py" | diff -u "$src/tests/fixtures.inc" - >"$work/drift"; then
        echo "ok   fixtures match the installed scene.py"
    else
        echo "FAIL fixtures differ from $scene_py:"
        cat "$work/drift"
        exit 1
    fi
fi
