#!/bin/bash
[ -e /run/tripwire/hits ] || { [ "${HYPR_DE_SEALED-}" = build-root ] && [ ! -e /run/systemd/private ]; } || exec "$(dirname -- "$0")/run" "$0"
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }
same() { if [ "$2" = "$want" ]; then ok "$1 $want"; else bad "$1 ${2:-nothing}, not $want"; fi; }

prefixed() { sed 's|%{_prefix}|/usr|g'; }

want=$(sed -n 's/^SCENE_PLUGIN=\([^ ]*\).*/\1/p' "$root/packaging/hypr-de.spec" | prefixed)
case $want in
    *%*) bad "hypr-de's RPM has no architecture, and names the plugin by a path that depends on one: $want" ;;
    /*)  ok "hypr-de's RPM names the plugin at $want on every architecture" ;;
    *)   bad "hypr-de's RPM does not say where the plugin is"; exit 1 ;;
esac

same "hypr-de's Arch package names it at" "$(sed -n 's/^ *SCENE_PLUGIN=\([^ ]*\).*/\1/p' "$root/packaging/PKGBUILD")"
same "an install from source names it at" "$(unset SCENE_PLUGIN; . "$root/packaging/paths.conf"; printf '%s' "$SCENE_PLUGIN")"
same "the plugin's own build installs it, under /usr, at" \
    "/usr/$(sed -n 's/^install(TARGETS hypr-de-scene LIBRARY DESTINATION \(.*\))$/\1/p' "$root/plugins/hypr-de-scene/CMakeLists.txt")/hypr-de-scene.so"

scene=$(prefixed <"$root/packaging/hypr-de-scene.spec")
if sed -n '/^%files/,/^%changelog/p' <<<"$scene" | grep -qxF "$want"; then
    ok "the hypr-de-scene RPM lists it in %files"
else
    bad "the hypr-de-scene RPM does not list $want in %files: $(sed -n '/^%files/,/^%changelog/p' <<<"$scene" | grep '\.so' | tr '\n' ' ')"
fi
if grep -qF "hl.plugin.load(\"$want\")" <<<"$scene"; then
    ok "the hypr-de-scene RPM's description gives the same line to opt in"
else
    bad "the hypr-de-scene RPM's description opts in with $(grep -o 'hl.plugin.load([^)]*)' <<<"$scene")"
fi

exit "$fail"
