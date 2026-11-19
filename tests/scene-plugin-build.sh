#!/bin/bash
[ -e /run/tripwire/hits ] || { [ "${HYPR_DE_SEALED-}" = build-root ] && [ ! -e /run/systemd/private ]; } || exec "$(dirname -- "$0")/run" "$0"
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

for tool in cmake pkg-config nm; do
    command -v "$tool" >/dev/null || { echo "skip  no $tool in this environment, so the plugin was not built"; exit 0; }
done
if ! pkg-config --exists hyprland; then
    echo "skip  no Hyprland headers in this environment (pkg-config finds no hyprland), so the plugin was not built"
    exit 0
fi

if cmake -S "$root/plugins/hypr-de-scene" -B "$work/build" -DCMAKE_BUILD_TYPE=Release >"$work/configure.log" 2>&1 \
    && cmake --build "$work/build" >"$work/build.log" 2>&1; then
    ok "builds against Hyprland $(pkg-config --modversion hyprland) headers"
else
    bad "does not build against Hyprland $(pkg-config --modversion hyprland) headers"
    tail -n 40 "$work/configure.log" "$work/build.log" 2>/dev/null
    exit 1
fi

symbols=$(nm -D --defined-only "$work/build/hypr-de-scene.so")
for entry in pluginAPIVersion pluginInit pluginExit; do
    grep -qw "$entry" <<<"$symbols" && ok "exports $entry" || bad "does not export $entry"
done

exit "$fail"
