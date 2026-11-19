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

plugin=$work/build/hypr-de-scene.so
symbols=$(nm -D --defined-only "$plugin")
for entry in pluginAPIVersion pluginInit pluginExit; do
    grep -qw "$entry" <<<"$symbols" && ok "exports $entry" || bad "does not export $entry"
done

loaded() { ldd "$1" | awk '$2 == "=>" && $3 ~ /^\// { print $3 }'; }
if hyprland=$(command -v Hyprland); then
    mapfile -t objects < <(printf '%s\n' "$hyprland"; loaded "$hyprland"; loaded "$plugin")
    provided=$(nm -D --defined-only "${objects[@]}" 2>/dev/null | awk 'NF >= 3 { sub(/@.*/, "", $NF); print $NF }' | sort -u)
    missing=$(nm -D --undefined-only "$plugin" | awk '$1 == "U" { sub(/@.*/, "", $2); print $2 }' | sort -u | comm -23 - <(printf '%s\n' "$provided"))
    if [ -z "$missing" ]; then
        ok "Hyprland and the libraries it loads provide every symbol the plugin needs"
    else
        bad "nothing Hyprland loads provides: $(tr '\n' ' ' <<<"$missing")"
    fi
else
    echo "skip  no Hyprland binary in this environment, so the plugin's symbols were not resolved against it"
fi

exit "$fail"
