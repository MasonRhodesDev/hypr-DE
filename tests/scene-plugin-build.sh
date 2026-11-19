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

loader=$work/build/hypr-de-scene.so
plugin=$work/build/hypr-de-scene-impl.so
for module in "$loader" "$plugin"; do
    symbols=$(nm -D --defined-only "$module")
    for entry in pluginAPIVersion pluginInit pluginExit; do
        grep -qw "$entry" <<<"$symbols" && ok "${module##*/} exports $entry" || bad "${module##*/} does not export $entry"
    done
done

extra=$(nm -D --defined-only "$loader" | awk '{ print $NF }' | grep -vxE 'pluginAPIVersion|pluginInit|pluginExit')
if [ -z "$extra" ]; then
    ok "the loader exports nothing but the entry points"
else
    bad "the loader also exports: $(tr '\n' ' ' <<<"$extra")"
fi

# glibc, libstdc++ and libgcc version every symbol; Hyprland and its libraries do not
imports=$(nm -D --undefined-only "$loader" | awk '$1 == "U" && $2 !~ /@/ { print $2 }')
if [ -z "$imports" ]; then
    ok "the loader needs no symbol from Hyprland, so no Hyprland upgrade can stop it loading"
else
    bad "the loader needs symbols a Hyprland upgrade can remove: $(tr '\n' ' ' <<<"$imports")"
fi
needed=$(readelf -dW "$loader" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | grep -vxE 'libc\.so\.6|libm\.so\.6|libstdc\+\+\.so\.6|libgcc_s\.so\.1')
if [ -z "$needed" ]; then
    ok "the loader links only the C and C++ runtimes"
else
    bad "the loader links: $(tr '\n' ' ' <<<"$needed")"
fi

installs=$(unset SCENE_PLUGIN; . "$root/packaging/paths.conf"; printf '%s' "$SCENE_PLUGIN")
private=$(dirname -- "$installs")/hypr-de-scene-impl.so
if DESTDIR="$work/stage" cmake --install "$work/build" --prefix /usr >"$work/install.log" 2>&1 && [ -f "$work/stage$installs" ] && [ -f "$work/stage$private" ]; then
    ok "installs the loader to $installs, where hypr-de's configuration loads it from, and the module beside it"
else
    bad "does not install to $installs and $private: $(find "$work/stage" -name '*.so' 2>/dev/null | sed "s|^$work/stage||" | tr '\n' ' ')"
fi

for module in "$loader" "$plugin"; do
    if nm -D "$module" | grep -q __hyprland_api_get_client_hash; then
        bad "${module##*/} shares the symbol that names its Hyprland build with every other plugin"
    else
        ok "${module##*/} keeps the name of its Hyprland build to itself"
    fi
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
