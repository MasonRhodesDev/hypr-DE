#!/bin/bash
# A monitor re-added during locked blanking must be blanked; one added to a
# lit lock screen (user typing) must not blank the session under their
# hands. Runs blank-guard.sh against stubbed hyprctl/session-locked.
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

mkdir -p "$work/bin" "$work/libexec"
sed -e "s|@LIBEXECDIR@|$work/libexec|g" \
    -e "s|^PATH=/usr/local/bin:/usr/bin:/bin|PATH=\"$work/bin:/usr/bin:/bin\"|" \
    "$root/dist/libexec/blank-guard.sh" > "$work/libexec/blank-guard.sh"
chmod +x "$work/libexec/blank-guard.sh"
# The two collaborators, stubbed. session-locked.sh: exit per $LOCKED_OK.
printf '#!/bin/sh\nexit "${LOCKED_OK:-1}"\n' > "$work/libexec/session-locked.sh"
# dpms-off-if-locked.sh: record that it ran.
printf '#!/bin/sh\necho ran >> "%s/blanked"\n' "$work" > "$work/libexec/dpms-off-if-locked.sh"
chmod +x "$work/libexec/session-locked.sh" "$work/libexec/dpms-off-if-locked.sh"
# hyprctl stub serves the monitors fixture.
printf '#!/bin/sh\ncat "%s/monitors.json"\n' "$work" > "$work/bin/hyprctl"
chmod +x "$work/bin/hyprctl"
export PATH="$work/bin:$PATH"

mon() { # name dpms disabled
  printf '{"name":"%s","dpmsStatus":%s,"disabled":%s}' "$1" "$2" "$3"
}
run() { rm -f "$work/blanked"; LOCKED_OK=$1 "$work/libexec/blank-guard.sh" "$3" >/dev/null 2>&1; [ -f "$work/blanked" ]; echo $?; }

echo "== re-add during an active blank joins it"
printf '[%s,%s,%s]' "$(mon DP-1 false false)" "$(mon DP-2 false false)" "$(mon HDMI-A-1 true false)" > "$work/monitors.json"
[ "$(run 0 - HDMI-A-1)" = 0 ] && ok "blanked" || bad "did not blank during an active blank"

echo "== lit lock screen: a new monitor must NOT blank the session"
printf '[%s,%s,%s]' "$(mon DP-1 true false)" "$(mon DP-2 true false)" "$(mon HDMI-A-1 true false)" > "$work/monitors.json"
[ "$(run 0 - HDMI-A-1)" = 1 ] && ok "left lit" || bad "blanked a lit lock screen"

echo "== not locked (or user toggle held): never blank"
printf '[%s,%s]' "$(mon DP-1 false false)" "$(mon HDMI-A-1 true false)" > "$work/monitors.json"
[ "$(run 1 - HDMI-A-1)" = 1 ] && ok "unlocked leaves it alone" || bad "blanked an unlocked desktop"

echo "== a disabled dark output does not count as an active blank"
printf '[%s,%s]' "$(mon DP-1 false true)" "$(mon HDMI-A-1 true false)" > "$work/monitors.json"
[ "$(run 0 - HDMI-A-1)" = 1 ] && ok "disabled output ignored" || bad "counted a disabled output as blanked"

echo "== only the re-added output dark (others lit): no action"
printf '[%s,%s]' "$(mon DP-1 true false)" "$(mon HDMI-A-1 false false)" > "$work/monitors.json"
[ "$(run 0 - HDMI-A-1)" = 1 ] && ok "self does not justify a blank" || bad "the re-added output justified its own blank"

exit $fail
