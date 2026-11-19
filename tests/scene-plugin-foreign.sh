#!/bin/bash
[ -e /run/tripwire/hits ] || { [ "${HYPR_DE_SEALED-}" = build-root ] && [ ! -e /run/systemd/private ]; } || exec "$(dirname -- "$0")/run" "$0"
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
src=$root/plugins/hypr-de-scene
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

for tool in cmake pkg-config; do
    command -v "$tool" >/dev/null || { echo "skip  no $tool in this environment, so the plugin was not loaded into another Hyprland"; exit 0; }
done
if ! pkg-config --exists hyprland; then
    echo "skip  no Hyprland headers in this environment (pkg-config finds no hyprland), so the plugin was not loaded into another Hyprland"
    exit 0
fi
if ! hyprland=$(command -v Hyprland); then
    echo "skip  no Hyprland binary in this environment, so the plugin was not loaded into another Hyprland"
    exit 0
fi

other=0123456789abcdef0123456789abcdef01234567
read -ra headers < <(pkg-config --cflags hyprland pixman-1 libdrm)
if ! { cmake -S "$src" -B "$work/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-include $src/tests/another-hyprland.h" \
        && cmake --build "$work/build" --parallel \
        && "${CXX:-c++}" -std=c++26 -shared -fPIC "${headers[@]}" -o "$work/neighbour.so" "$src/tests/neighbour-plugin.cpp" \
        && "${CXX:-c++}" -std=c++23 -Wall -Wextra -Werror -shared -fPIC -o "$work/host.so" "$src/tests/foreign-host.cpp"; } >"$work/build.log" 2>&1; then
    echo "FAIL the plugin, built as if for Hyprland $other, or its test host does not build"
    tail -n 40 "$work/build.log"
    exit 1
fi

load() {
    SCENE_PLUGIN=$work/build/hypr-de-scene.so SCENE_NEIGHBOUR=${1-} LD_PRELOAD=$work/host.so "$hyprland" --version 2>&1
}

quiet() {
    local out=$1 where=$2 running logged
    running=$(sed -n 's/^running //p' <<<"$out")
    logged=$(grep -c '^log ' <<<"$out")

    if grep -qx 'outcome returned' <<<"$out"; then
        ok "$where: init returns, so Hyprland shows no failed-to-load notification"
    else
        bad "$where: init did not return: $(grep '^outcome ' <<<"$out" || tail -n 3 <<<"$out")"
    fi
    if grep -q "^description idle, .*built for Hyprland ${other}_.* but $running is running\. Rebuild the hypr-de-scene package" <<<"$out"; then
        ok "$where: the description says idle, names both builds and says to rebuild"
    else
        bad "$where: description is: $(sed -n 's/^description //p' <<<"$out")"
    fi
    if [ "$logged" = 1 ] && grep -q "^log 3 idle, .*built for Hyprland ${other}_.* but $running is running" <<<"$out"; then
        ok "$where: one error line for the journal"
    else
        bad "$where: wrote $logged journal lines: $(grep '^log ' <<<"$out")"
    fi
    if grep -qx 'syslog closed' <<<"$out"; then
        ok "$where: leaves syslog closed"
    else
        bad "$where: leaves syslog open"
    fi
}

quiet "$(load)" "in a Hyprland it was not built for"

out=$(load "$work/neighbour.so")
if [ "$(sed -n 's/^neighbour //p' <<<"$out")" = "$(sed -n 's/^running //p' <<<"$out")" ]; then
    quiet "$out" "after a neighbour plugin built for the running Hyprland"
else
    bad "the neighbour plugin does not name the running Hyprland: $(grep -E '^(neighbour|running) ' <<<"$out" | tr '\n' ' ')"
fi

exit "$fail"
