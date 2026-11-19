#!/bin/bash
set -uo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: nested-readback.sh HYPRLAND PLUGIN DATA_DIR OUT_DIR [SPLASH]

Runs HYPRLAND nested in a headless sway inside bubblewrap, with only a render
node from the host, and writes what each output committed to OUT_DIR:
  dumps/   PPM readbacks the plugin took of committed buffers
  shots/   screenshots of the host compositor every 100 ms
  log      the plugin's own lines
  plugins.txt  hyprctl plugin list before the unload
PLUGIN is the loader, and its directory is shared so the module beside it loads.
SPLASH is a client that maps the hand-off layer; without it the scene leaves
on its timeout. The run ends by unloading the plugin and then stopping
Hyprland, and fails if Hyprland dies or does not stop cleanly.

NESTED_LIB_DIR     libraries to prefer over the system's, for a host compositor
                   Hyprland's nested backend does not accept as is
SCENE_TIMEOUT      seconds before the scene leaves on its own (6)
SCENE_RUN_SECONDS  seconds to keep the session up after its outputs exist (8)
SCENE_UNLOAD       0 leaves the plugin loaded until Hyprland stops, as a logout does (1)
SCENE_AFTER_UNLOAD seconds to keep it up after the plugin is unloaded (12)

Check the result with readback-check.py.
USAGE
    exit 2
}

[ $# -ge 4 ] || usage
hyprland=$(readlink -f -- "$1")
plugin=$(readlink -f -- "$2")
data=$(readlink -f -- "$3")
out=$(readlink -f -- "$4")
splash=${5:-}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

node=${RENDER_NODE:-}
if [ -z "$node" ]; then
    for n in /dev/dri/renderD*; do
        [ -c "$n" ] && { node=$n; break; }
    done
fi
[ -n "$node" ] || { echo "nested-readback: no DRM render node" >&2; exit 2; }
for tool in bwrap sway grim; do
    command -v "$tool" >/dev/null || { echo "nested-readback: $tool is not installed" >&2; exit 2; }
done

mkdir -p "$out/dumps" "$out/shots"

libs=()
if [ -n "${NESTED_LIB_DIR-}" ]; then
    lib_dir=$(readlink -f -- "$NESTED_LIB_DIR")
    libs=(--ro-bind "$lib_dir" "$lib_dir" --setenv LD_LIBRARY_PATH "$lib_dir")
fi

system=()
for d in /usr /etc /opt /bin /sbin /lib /lib64; do
    if [ -L "$d" ]; then
        system+=(--symlink "$(readlink -- "$d")" "$d")
    elif [ -d "$d" ]; then
        system+=(--ro-bind "$d" "$d")
    fi
done

exec bwrap --unshare-all --die-with-parent --new-session --cap-drop ALL \
    "${system[@]}" --dev /dev --dev-bind "$node" "$node" --proc /proc --ro-bind /sys /sys \
    --tmpfs /tmp --tmpfs /run --tmpfs /var --dir /tmp/home --dir /run/rt \
    --ro-bind "$here" "$here" \
    --ro-bind "$hyprland" "$hyprland" --ro-bind "$(dirname -- "$plugin")" "$(dirname -- "$plugin")" --ro-bind "$data" "$data" \
    --bind "$out" "$out" \
    --clearenv "${libs[@]}" \
    --setenv PATH "$(dirname -- "$hyprland"):/usr/local/bin:/usr/bin:/bin" \
    --setenv HOME /tmp/home \
    --setenv XDG_RUNTIME_DIR /run/rt \
    --setenv LANG C.UTF-8 \
    --setenv RENDER_NODE "$node" \
    --setenv SCENE_TIMEOUT "${SCENE_TIMEOUT:-6}" \
    --setenv SCENE_RUN_SECONDS "${SCENE_RUN_SECONDS:-8}" \
    --setenv SCENE_UNLOAD "${SCENE_UNLOAD:-1}" \
    --setenv SCENE_AFTER_UNLOAD "${SCENE_AFTER_UNLOAD:-12}" \
    --chdir "$out" \
    /bin/bash "$here/nested-inner.sh" "$hyprland" "$plugin" "$data" "$out" "$splash"
