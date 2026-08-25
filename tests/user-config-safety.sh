#!/bin/bash
# The session must not destroy or silently break the user's own state.
# See issue #18: a config rewritten on every screenshot, and a bar module that
# emits invalid JSON when its cache is malformed.
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

echo "== the wallpaper unit survives a path with a space"
unit="$root/dist/systemd/user/swaybg.service"
# systemd expands ${VAR} as ONE argument and $VAR split on whitespace, so the
# braces are load-bearing. Verified with systemd-run: '${WP}' over
# "/tmp/a b.png" yields arg2=[/tmp/a b.png], while '$WP' yields
# arg2=[/tmp/a] arg3=[b.png].
if grep -q 'ExecStart=.*-i \${WALLPAPER_PATH}' "$unit"; then
    ok "ExecStart uses the braced, non-splitting form"
else
    grep -n ExecStart "$unit"
    bad "ExecStart must reference \${WALLPAPER_PATH} braced, or a path with a space is torn in half"
fi
grep -q '^ConditionEnvironment=WALLPAPER_PATH' "$unit" \
    && ok "the unit is skipped until a wallpaper is set" \
    || bad "with WALLPAPER_PATH unset, swaybg gets an empty -i and restart-loops every 3s"

echo
echo "== a screenshot does not overwrite the user's swappy config"
# The seeding block, lifted out and pointed at a fixture DATADIR.
datadir="$work/datadir"; mkdir -p "$datadir/swappy"
cp "$root/dist/swappy/config" "$datadir/swappy/config"
block=$(sed -n '/^SWAPPY_CFG=/,/^fi$/p' "$root/dist/bin/hypr-de-snip" | sed "s|@DATADIR@|$datadir|g")
if [ -z "$block" ]; then
    bad "could not find the swappy seeding block -- the cases below cannot run"
    block='false'
fi

home1="$work/h1"; mkdir -p "$home1"
HOME="$home1" bash -c "$block"
if [ -e "$home1/.config/swappy/config" ]; then
    ok "seeded a config when the user had none"
    cmp -s "$home1/.config/swappy/config" "$datadir/swappy/config" \
        && ok "seeded from the packaged copy (one source of truth)" \
        || bad "seeded content differs from the packaged config"
else
    bad "no config seeded"
fi

home2="$work/h2"; mkdir -p "$home2/.config/swappy"
printf '[Default]\nsave_dir=%s/Elsewhere\nline_size=1\n' "$home2" > "$home2/.config/swappy/config"
before=$(cat "$home2/.config/swappy/config")
HOME="$home2" bash -c "$block"
if [ "$block" = false ]; then
    bad "no seeding block ran, so 'left it alone' proves nothing"
elif [ "$(cat "$home2/.config/swappy/config")" = "$before" ]; then
    ok "left an existing config alone"
else
    bad "CLOBBERED the user's swappy config"
fi

# ...and nothing writes it unconditionally any more.
grep -qE 'cat > *~?.*swappy/config' "$root/dist/bin/hypr-de-snip" \
    && bad "still writes the swappy config unconditionally" \
    || ok "no unconditional write"

echo
echo "== the colorpicker module always emits valid JSON"
cp_home="$work/cp"; mkdir -p "$cp_home/.cache/colorpicker"
emit() { HOME="$cp_home" bash "$root/dist/libexec/waybar-colorpicker.sh" -j 2>/dev/null; }

printf '#ff0000\n#00ff00\n' > "$cp_home/.cache/colorpicker/colors"
out=$(emit)
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "valid colors -> valid JSON"; else printf '%s\n' "$out"; bad "valid colors -> invalid JSON"; fi
printf '%s' "$out" | jq -r .tooltip | grep -q '#00ff00' && ok "lists the saved colors" || bad "colors missing from the tooltip"

# A quote in the cache used to end the JSON string; markup used to be injected.
printf '#ff0000\n<b>&"junk\n\n#zz\n' > "$cp_home/.cache/colorpicker/colors"
out=$(emit)
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    ok "malformed cache -> still valid JSON"
else
    printf '%s\n' "$out"
    bad "malformed cache -> invalid JSON (waybar drops the module)"
fi
if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    bad "cannot check the tooltip: the JSON did not parse"
elif printf '%s' "$out" | jq -r .tooltip | grep -q 'junk'; then
    bad "a non-color line reached the tooltip"
else
    ok "non-color lines are dropped"
fi

: > "$cp_home/.cache/colorpicker/colors"
emit | jq -e . >/dev/null 2>&1 && ok "empty cache -> valid JSON" || bad "empty cache -> invalid JSON"

printf 'not-a-color\n' > "$cp_home/.cache/colorpicker/colors"
emit | jq -e . >/dev/null 2>&1 && ok "junk first line -> valid JSON" || bad "junk first line -> invalid JSON"

echo
[ "$fail" -eq 0 ] && { echo "user config is safe"; exit 0; }
exit 1
