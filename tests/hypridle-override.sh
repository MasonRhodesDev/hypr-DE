#!/bin/bash
# A host sets its own idle timeouts without copying the packaged policy.
# ~/.config/hypr-de/hypridle.conf may redefine the `$name = seconds` knobs the
# packaged hypridle.conf declares; hypridle-launch splices them in after the
# defaults and runs the copy. Everything else in the policy is the decided
# model and must reach hypridle byte for byte.
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

fixtures="$root/tests/fixtures/hypridle-override"
chmod +x "$fixtures/hypridle"
src="$root/dist/libexec/hypridle-launch"
policy="$work/policy.conf"
sed 's|@LIBEXECDIR@|/nonexistent|g' "$root/dist/hypr/hypridle.conf" > "$policy"
marker='# hypr-de: host overrides go below this line (hypridle-launch)'

# The launcher pins PATH and its binary list to root-owned places (BAR-017);
# the suite runs a copy with both redirected at the fixtures, the way
# lock-policy.sh does for the other libexec helpers.
grep -q '^PATH=/usr/local/bin:/usr/bin:/bin; export PATH$' "$src" \
    && ok "the launcher pins PATH to root-owned directories" \
    || bad "the launcher must pin PATH (the user manager's PATH has ~/.local/bin)"
grep -v '^[[:space:]]*#' "$src" | grep -q 'command -v\|which ' \
    && bad "the launcher resolves something through \$PATH" \
    || ok "no command -v / which in the launcher"
launch="$work/hypridle-launch"
sed -e "s|^PATH=.*|PATH=$fixtures:/usr/bin:/bin; export PATH|" \
    -e "s|^HYPRIDLE_CANDIDATES=.*|HYPRIDLE_CANDIDATES=\"$work/no-such-hypridle $fixtures/hypridle\"|" \
    -e "s|^POLICY=.*|POLICY=$policy|" "$src" > "$launch"
chmod +x "$launch"

export HYPRIDLE_LOG="$work/argv" HYPRIDLE_CONF_COPY="$work/handed.conf"
home="$work/home"; export HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_RUNTIME_DIR="$work/run"
override="$XDG_CONFIG_HOME/hypr-de/hypridle.conf"
run_launch() { # argv lands in $HYPRIDLE_LOG, stderr in $work/err
    : > "$HYPRIDLE_LOG"; rm -f "$HYPRIDLE_CONF_COPY"
    mkdir -p "$XDG_RUNTIME_DIR"
    bash "$launch" 2> "$work/err"
}
handed() { head -n1 "$HYPRIDLE_LOG"; }
# The assembled file minus its header and the spliced lines must be the policy.
policy_intact() { # policy_intact <assembled> <accepted-lines-file>
    grep -vxF -f "$2" "$1" | sed 1d | cmp -s - "$policy"
}

echo "== the packaged policy declares the knobs, and every listener uses one"
mapfile -t knobs < <(sed -n "1,/^$marker\$/p" "$policy" | sed -n 's/^\$\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1=\2/p')
printf '%s\n' "${knobs[@]}" | grep -qx 'lock_timeout=180'    && ok "\$lock_timeout defaults to 180"    || bad "\$lock_timeout default: ${knobs[*]}"
printf '%s\n' "${knobs[@]}" | grep -qx 'blank_timeout=30'    && ok "\$blank_timeout defaults to 30"    || bad "\$blank_timeout default: ${knobs[*]}"
printf '%s\n' "${knobs[@]}" | grep -qx 'suspend_timeout=900' && ok "\$suspend_timeout defaults to 900" || bad "\$suspend_timeout default: ${knobs[*]}"
[ "${#knobs[@]}" -eq 3 ] && ok "exactly three knobs" || bad "knob set changed: ${knobs[*]}"
raw=$(grep -nE '^[[:space:]]*timeout[[:space:]]*=[[:space:]]*[0-9]' "$policy")
[ -z "$raw" ] && ok "no listener carries a literal timeout" || { printf '%s\n' "$raw"; bad "a listener timeout bypasses the knobs"; }
uses=$(grep -cE '^[[:space:]]*timeout[[:space:]]*=[[:space:]]*\$(lock|blank|suspend)_timeout' "$policy")
[ "$uses" -eq 3 ] && ok "three listeners, three knobs" || bad "expected 3 knob uses, found $uses"
grep -qxF "$marker" "$policy" && ok "the splice marker is present" || bad "no splice marker in hypridle.conf"
# hyprlang: a variable must be defined before the line that uses it.
first_use=$(grep -nE '\$(lock|blank|suspend)_timeout' "$policy" | grep -v '^[0-9]*:\$' | head -n1 | cut -d: -f1)
marker_at=$(grep -nxF "$marker" "$policy" | cut -d: -f1)
[ "$marker_at" -lt "$first_use" ] && ok "defaults and marker come before the first use (line $marker_at < $first_use)" \
    || bad "a knob is used (line $first_use) before the marker (line $marker_at)"

echo
echo "== the drop-in hands hypridle to the launcher"
dropin="$root/dist/systemd/user/hypridle.service.d/hypr-de.conf"
grep -q '^ExecStart=@LIBEXECDIR@/hypridle-launch$' "$dropin" && ok "ExecStart is the launcher" || { grep ExecStart "$dropin"; bad "ExecStart is not the launcher"; }
grep -v '^[[:space:]]*#' "$dropin" | grep -q 'command -v\|which ' && bad "the drop-in resolves through \$PATH" || ok "nothing in the drop-in resolves through \$PATH"

echo
echo "== no override file: the packaged policy runs untouched"
run_launch
[ "$(handed)" = "-c $policy" ] && ok "hypridle got -c $policy" || bad "hypridle got: $(handed)"
[ -e "$XDG_RUNTIME_DIR/hypr-de/hypridle.conf" ] && bad "a runtime copy was made with nothing to splice" || ok "no runtime copy made"
[ -s "$work/err" ] && { cat "$work/err"; bad "noise on stderr with no override"; } || ok "silent"

echo
echo "== a host override is spliced in after the defaults, policy intact"
mkdir -p "$(dirname "$override")"
cat > "$override" <<'O'
# this laptop locks later
$lock_timeout = 600   # ten minutes

  $suspend_timeout=1800
O
run_launch
assembled="$XDG_RUNTIME_DIR/hypr-de/hypridle.conf"
[ "$(handed)" = "-c $assembled" ] && ok "hypridle got the assembled copy" || bad "hypridle got: $(handed)"
cmp -s "$assembled" "$HYPRIDLE_CONF_COPY" && ok "the copy handed over is the one assembled" || bad "handed file differs from the assembled one"
[ "$(stat -c %a "$XDG_RUNTIME_DIR/hypr-de")" = 700 ] && ok "runtime dir is 0700" || bad "runtime dir mode $(stat -c %a "$XDG_RUNTIME_DIR/hypr-de")"
printf '$lock_timeout = 600\n$suspend_timeout = 1800\n' > "$work/accepted"
policy_intact "$assembled" "$work/accepted" && ok "every policy line reaches hypridle byte for byte" \
    || { diff <(grep -vxF -f "$work/accepted" "$assembled" | sed 1d) "$policy" | head; bad "the policy text was altered"; }
# hyprlang takes the latest definition for the lines that follow: the host's
# value must come after the default and before the listener that uses it.
d=$(grep -nE '^\$lock_timeout[[:space:]]*=[[:space:]]*180([[:space:]]|$)' "$assembled" | cut -d: -f1 | head -n1)
h=$(grep -nxF '$lock_timeout = 600' "$assembled" | cut -d: -f1 | head -n1)
u=$(grep -nE '^[[:space:]]*timeout[[:space:]]*=[[:space:]]*\$lock_timeout' "$assembled" | cut -d: -f1 | head -n1)
d=${d:-0}; h=${h:-0}; u=${u:-0}
if [ "$d" -gt 0 ] && [ "$h" -gt "$d" ] && [ "$u" -gt "$h" ]; then
    ok "default ($d) < host value ($h) < use ($u): the host's 600 wins"
else
    bad "ordering wrong: default=$d host=$h use=$u"
fi
grep -q 'ten minutes\|this laptop' "$assembled" && bad "override comments leaked into the config" || ok "override comments are not copied"
grep -q 'host timeouts from' "$work/err" && ok "the journal says which values were applied" || bad "no applied-values line on stderr"
[ "$(grep -c 'dropped' "$work/err")" -eq 0 ] && ok "nothing dropped" || { cat "$work/err"; bad "a valid line was dropped"; }

echo
echo "== only knobs get through; everything else is reported and dropped"
cat > "$override" <<'O'
$lock_timeout = 300
listener {
  timeout = 5
  on-timeout = rm -rf ~
}
general { lock_cmd = evil }
on-timeout = evil
$blank_timeout = abc
$blank_timeout = 0
$blank_timeout = 99999999999
$suspend_timeout = -5
$not_a_knob = 5
$suspend_timeout = 4294967
O
run_launch
assembled="$XDG_RUNTIME_DIR/hypr-de/hypridle.conf"
[ "$(handed)" = "-c $assembled" ] && ok "the good lines still produced a copy" || bad "hypridle got: $(handed)"
printf '$lock_timeout = 300\n$suspend_timeout = 4294967\n' > "$work/accepted"
policy_intact "$assembled" "$work/accepted" && ok "nothing but the two accepted knobs was added" \
    || { diff <(grep -vxF -f "$work/accepted" "$assembled" | sed 1d) "$policy" | head; bad "a rejected line reached hypridle"; }
for needle in 'rm -rf' 'evil' 'not_a_knob' '$blank_timeout = abc' '$blank_timeout = 0' '99999999999' '$suspend_timeout = -5'; do
    grep -qF -- "$needle" "$assembled" && bad "'$needle' reached the config" || ok "'$needle' dropped"
done
dropped=$(grep -c 'dropped' "$work/err")
[ "$dropped" -eq 11 ] && ok "eleven lines reported with file:line" || { cat "$work/err"; bad "expected 11 dropped reports, got $dropped"; }
grep -q "hypridle.conf:8: \$blank_timeout must be a whole number" "$work/err" && ok "a non-number names its line" || bad "line 8 report missing"
grep -q "hypridle.conf:12: no such knob \$not_a_knob (the policy declares: lock_timeout blank_timeout suspend_timeout)" "$work/err" && ok "an unknown knob names the known ones" || bad "line 12 report missing"
grep -q "4294967 seconds" "$work/err" && ok "the range is stated" || bad "no range in the out-of-range report"

echo
echo "== an override with nothing usable runs the packaged policy"
printf '# just a note\n\n' > "$override"
run_launch
[ "$(handed)" = "-c $policy" ] && ok "comments only: packaged policy" || bad "hypridle got: $(handed)"
printf 'on-timeout = evil\n' > "$override"
run_launch
[ "$(handed)" = "-c $policy" ] && ok "every line dropped: packaged policy" || bad "hypridle got: $(handed)"
grep -q dropped "$work/err" && ok "...and said so" || bad "silent drop"

echo
echo "== without a runtime dir the override is ignored, never written to /tmp"
printf '$lock_timeout = 600\n' > "$override"
: > "$HYPRIDLE_LOG"
env -u XDG_RUNTIME_DIR bash "$launch" 2> "$work/err"
[ "$(handed)" = "-c $policy" ] && ok "packaged policy" || bad "hypridle got: $(handed)"
grep -q "XDG_RUNTIME_DIR is unset" "$work/err" && ok "warned" || bad "no warning"
[ -e /tmp/hypr-de/hypridle.conf ] && bad "wrote under /tmp" || ok "nothing under /tmp"

echo
echo "== a policy without the marker runs unchanged"
sed -i "/^$marker\$/d" "$policy"
run_launch
[ "$(handed)" = "-c $policy" ] && ok "packaged policy" || bad "hypridle got: $(handed)"
grep -q "no override marker" "$work/err" && ok "warned" || bad "no warning"

echo
[ "$fail" -eq 0 ] && { echo "per-host idle timeouts work"; exit 0; }
exit 1
