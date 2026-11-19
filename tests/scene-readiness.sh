#!/bin/bash
[ -e /run/tripwire/hits ] || { [ "${HYPR_DE_SEALED-}" = build-root ] && [ ! -e /run/systemd/private ]; } || exec "$(dirname -- "$0")/run" "$0"
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
src=$root/plugins/hypr-de-scene
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cxx=${CXX:-c++}
command -v "$cxx" >/dev/null || { echo "FAIL no C++ compiler ($cxx) to build the scene readiness test"; exit 1; }

"$cxx" -std=c++23 -Wall -Wextra -Wconversion -Wshadow -Werror -o "$work/readiness" \
    "$src/tests/readiness.cpp" "$src/src/Readiness.cpp" \
    || { echo "FAIL the scene readiness test does not compile"; exit 1; }
"$work/readiness"
