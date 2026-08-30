#!/bin/bash
# swaybg must show the wallpaper the lock screen shows.
#
# Both now read ~/.config/appearance-profiles/default.toml. Before this,
# swaybg read ${WALLPAPER_PATH} from the user manager's environment, which
# is frozen at manager start and outranked by any set-environment override
# for as long as the manager lives - eight days, under Linger=yes, on
# 2026-08-30. The stubs below make the launcher run without a compositor:
# a fake swaybg records what it was asked to display.
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

# Stage the launcher with tokens substituted, and a swaybg that only records.
mkdir -p "$work/bin" "$work/share/wallpapers" "$work/cfg/appearance-profiles"
sed "s|@DATADIR@|$work/share|g" "$root/dist/libexec/swaybg-launch" > "$work/swaybg-launch"
chmod +x "$work/swaybg-launch"
sed -i "s|exec /usr/bin/swaybg|exec $work/bin/swaybg|" "$work/swaybg-launch"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/swaybg.args"\n' "$work" > "$work/bin/swaybg"
chmod +x "$work/bin/swaybg"
: > "$work/share/wallpapers/default.png"
: > "$work/cfg/mine.png"
run() { HOME="$work" XDG_CONFIG_HOME="$work/cfg" "$work/swaybg-launch" 2>"$work/err"; }
shown() { sed -n '2p' "$work/swaybg.args"; }

echo "== the registry's background is what swaybg shows"
printf 'version = 1\n\n[background]\npath = "%s/cfg/mine.png"\n\n[output]\n' "$work" \
    > "$work/cfg/appearance-profiles/default.toml"
run
[ "$(shown)" = "$work/cfg/mine.png" ] && ok "swaybg -i <registry path>" || bad "showed $(shown)"

echo "== a path with a space survives"
: > "$work/cfg/my wall.png"
printf '[background]\npath = "%s/cfg/my wall.png"\n' "$work" > "$work/cfg/appearance-profiles/default.toml"
run
[ "$(shown)" = "$work/cfg/my wall.png" ] && ok "space preserved as one argument" || bad "showed $(shown)"

echo "== a key of the same name in another section is not the background"
printf '[output]\npath = "/wrong.png"\n\n[background]\npath = "%s/cfg/mine.png"\n' "$work" \
    > "$work/cfg/appearance-profiles/default.toml"
run
[ "$(shown)" = "$work/cfg/mine.png" ] && ok "only [background].path is read" || bad "showed $(shown)"

echo "== no registry: the packaged default, not a crash loop"
rm "$work/cfg/appearance-profiles/default.toml"
run
[ "$(shown)" = "$work/share/wallpapers/default.png" ] && ok "falls back to default" || bad "showed $(shown)"

echo "== an unreadable registry path: the default, and a note on stderr"
printf '[background]\npath = "/does/not/exist.png"\n' > "$work/cfg/appearance-profiles/default.toml"
run
[ "$(shown)" = "$work/share/wallpapers/default.png" ] && grep -q unreadable "$work/err" \
    && ok "unreadable path falls back and says so" || bad "showed $(shown); err: $(cat "$work/err")"

echo "== the environment is no longer a source of truth"
printf '[background]\npath = "%s/cfg/mine.png"\n' "$work" > "$work/cfg/appearance-profiles/default.toml"
WALLPAPER_PATH=/stale/from/env.png run
[ "$(shown)" = "$work/cfg/mine.png" ] && ok "WALLPAPER_PATH in the environment is ignored" || bad "showed $(shown)"
grep -v '^[[:space:]]*#' "$root/dist/systemd/user/swaybg.service" | grep -q 'ConditionEnvironment\|\${WALLPAPER_PATH}' \
    && bad "swaybg.service still consults the environment" || ok "swaybg.service does not consult the environment"
grep -v '^[[:space:]]*#' "$root/dist/bin/hypr-de-set-wallpaper" | grep -q 'set-environment' \
    && bad "the setter still plants a set-environment override" || ok "the setter plants no override"

exit $fail
