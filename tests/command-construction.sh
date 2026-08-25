#!/bin/bash
# Commands and Lua dispatches are built from argv and quoted literals, never
# by interpolating a value into a string a shell or a Lua parser will read.
# See issue #18. Most of these values are not attacker-settable today; the
# point is that the shape does not depend on that staying true.
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

echo "== nothing shipped runs a built string through a shell"
hits=$(grep -rn "shell=True" "$root/dist" 2>/dev/null)
[ -z "$hits" ] && ok "no shell=True in dist/" || { printf '%s\n' "$hits"; bad "shell=True in dist/"; }

echo
echo "== no gawk-only three-argument match()"
# mawk and busybox awk silently return nothing for match(s, re, arr), so a
# gawk-ism is a value that quietly becomes empty on another distro.
hits=$(grep -rnE 'match\(.+,.+,.+\)' "$root/dist" 2>/dev/null)
[ -z "$hits" ] && ok "no three-argument match()" || { printf '%s\n' "$hits"; bad "gawk-only match()"; }

echo
echo "== the media module builds argv, not a command line"
res=$(cd "$root" && python3 - <<'PY'
import importlib.util, subprocess, sys
spec = importlib.util.spec_from_file_location("wm", "dist/libexec/waybar-mediaplayer.py")
m = importlib.util.module_from_spec(spec); sys.modules["wm"] = m
spec.loader.exec_module(m)
seen = []
def fake(cmd, **kw):
    seen.append(cmd)
    return b""
m.subprocess.check_output = fake
m.run("playerctl", "-p", 'evil"; id #', "metadata", "artist")
arg = seen[0]
print("ARGV" if isinstance(arg, (list, tuple)) else "STRING", arg)
PY
)
case "$res" in
    ARGV*) ok "run() passes argv: ${res#ARGV }" ;;
    *)     bad "run() built a command string: $res" ;;
esac

echo
echo "== Lua dispatch values are quoted literals"
# The two implementations must agree, so a workspace name cannot mean one
# thing to the Python path and another to the shell path.
py=$(cd "$root" && HYPRLAND_INSTANCE_SIGNATURE=test XDG_RUNTIME_DIR="$work" python3 - <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bgf", "dist/gaming/bp-game-focus.py")
m = importlib.util.module_from_spec(spec); sys.modules["bgf"] = m
spec.loader.exec_module(m)
for v in ['games', 'a"b', 'a\\b', 'x") os.execute("id']:
    print(m.lua_str(v))
PY
)
# Same helper, lifted out of the shell implementation.
eval "$(grep -m1 '^\s*lua_str()' "$root/dist/libexec/swaync-focus-sender.sh" | sed 's/^[[:space:]]*//')"
sh_out=$(for v in 'games' 'a"b' 'a\b' 'x") os.execute("id'; do lua_str "$v"; echo; done)
if [ "$(printf '%s\n' "$py" | grep -c .)" -ne 4 ]; then
    bad "the python quoter produced $(printf '%s\n' "$py" | grep -c .) of 4 lines -- is lua_str present?"
elif [ "$(printf '%s\n' "$sh_out" | grep -c .)" -ne 4 ]; then
    bad "the shell quoter produced $(printf '%s\n' "$sh_out" | grep -c .) of 4 lines -- is lua_str present?"
elif [ "$py" = "$sh_out" ]; then
    ok "python and shell quoting agree"
    printf '%s\n' "$py" | sed 's/^/     /'
else
    printf 'python:\n%s\nshell:\n%s\n' "$py" "$sh_out"
    bad "the two Lua quoters disagree"
fi
# Substring tests cannot tell \" from ": strip the outer quotes and look for
# a quote that is not preceded by a backslash.
breakout=$(printf '%s' "$py" | tail -1)
inner=${breakout#\"}; inner=${inner%\"}
if [ -z "$inner" ]; then
    bad "no quoted literal to inspect -- the quoter produced nothing"
elif printf '%s' "$inner" | grep -qP '(?<!\\)"'; then
    printf '   literal body: %s\n' "$inner"
    bad "an unescaped quote survived inside the literal"
else
    ok "every quote inside the literal is escaped (breakout neutralised)"
fi

echo
echo "== no raw interpolation left at the dispatch sites"
# Any dispatch line that interpolates a value must route it through lua_str.
raw=$(grep -rn 'hl\.dsp' "$root/dist/libexec/swaync-focus-sender.sh" "$root/dist/gaming/bp-game-focus.py" 2>/dev/null \
      | grep -E '\{[a-z_]|\$[0-9a-zA-Z_]' \
      | grep -v 'lua_str')
[ -z "$raw" ] && ok "every interpolating dispatch goes through lua_str" \
    || { printf '%s\n' "$raw"; bad "raw interpolation at a dispatch site"; }

echo
[ "$fail" -eq 0 ] && { echo "command construction is safe"; exit 0; }
exit 1
