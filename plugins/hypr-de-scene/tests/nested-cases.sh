#!/bin/bash
set -uo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: nested-cases.sh HYPRLAND PLUGIN DATA_DIR OUT_DIR SCENE_PY [CASE...]

Runs the boot scene's readiness cases, each in its own sealed nested session
from nested-readback.sh, and checks each with nested-check.py. The readback
case is also checked against SCENE_PY, desktop-boot's lib/scene.py, with
readback-check.py. Without CASE it runs them all:
  readback  ten outputs held until the timeout, drawn as scene.py places them
  N1   ready with nothing expected
  N2   a wallpaper declared, then mapped a second later
  N2b  Hyprland's own wallpaper and nothing else
  N3   a session that never speaks
  N4   a declared layer that never maps
  N5   an output added during the hold
  N6   a layer on one output only
  N7   a session lock during the hold
  N8   hyprctl scene release, and commands the scene refuses
  N9   Hyprland started without a service manager
  N10  keys typed into a window under the scene
  unload  the plugin unloaded while the scene covers, as a logout during the hold
The cases also need swaybg, foot, wtype and hyprlock.
NESTED_LIB_DIR is passed on to nested-readback.sh.
USAGE
    exit 2
}

[[ $# -ge 5 ]] || usage
hyprland=$1 plugin=$2 data=$3 out=$4 scene_py=$5
shift 5
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cases=("$@")
[[ ${#cases[@]} -gt 0 ]] || cases=(readback N1 N2 N2b N3 N4 N5 N6 N7 N8 N9 N10 unload)
for tool in swaybg foot wtype hyprlock; do
    command -v "$tool" >/dev/null || { echo "nested-cases: $tool is not installed" >&2; exit 2; }
done

failed=()
for case in "${cases[@]}"; do
    run=$out/$case
    rm -rf -- "$run"
    mkdir -p -- "$run"
    echo "== $case"
    if ! SCENE_AFTER_UNLOAD=${SCENE_AFTER_UNLOAD:-2} timeout 120 "$here/nested-readback.sh" "$hyprland" "$plugin" "$data" "$run" "$case" >"$run/harness.log" 2>&1; then
        echo "FAIL $case: the nested session did not run cleanly, see $run/harness.log"
        tail -n 3 "$run/harness.log"
        failed+=("$case")
        continue
    fi
    ok=1
    python3 "$here/nested-check.py" "$run" "$case" || ok=0
    if [[ "$case" = readback ]]; then
        python3 "$here/readback-check.py" "$run" "$data" "$scene_py" || ok=0
    fi
    [[ "$ok" = 1 ]] || failed+=("$case")
done

if [[ ${#failed[@]} -gt 0 ]]; then
    echo "nested-cases: failed ${failed[*]}"
    exit 1
fi
echo "nested-cases: all ${#cases[@]} cases passed"
