#!/bin/bash
# Screen-share consent must not be replayed to a caller that did not ask for
# it. See issue #17: the cache was keyed on elapsed time alone, so any process
# opening a ScreenCast session within 15s inherited the user's screen or
# window with no picker shown.
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
picker_script="$root/dist/libexec/share-picker-cached"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

export XDG_RUNTIME_DIR="$work"
calls="$work/picker-calls"

# Stand-in picker: records every invocation, answers with a selection.
cat > "$work/picker" <<'PICKER'
#!/bin/sh
echo x >> "$PICKER_CALLS"
echo "[SELECTION]0/screen:DP-1"
exit "${PICKER_STATUS:-0}"
PICKER
# Stand-in busctl: prints a portal tree for whatever clients CLIENTS names.
cat > "$work/busctl" <<'BUSCTL'
#!/bin/sh
[ "${BUSCTL_FAIL:-0}" = 1 ] && exit 1
for c in ${CLIENTS:-}; do
    echo "        └─ /org/freedesktop/portal/desktop/session/$c/token123"
done
BUSCTL
chmod +x "$work/picker" "$work/busctl"
export PICKER_CALLS="$calls" XDPH_PICKER="$work/picker" XDPH_BUSCTL="$work/busctl"

run() { CLIENTS="$1" bash "$picker_script" --allow-token >"$work/out" 2>"$work/err"; }
ncalls() { [ -f "$calls" ] && wc -l < "$calls" | tr -d ' ' || echo 0; }
reset() { rm -f "$calls" "$XDG_RUNTIME_DIR/xdph-share-picker.cache"; }

echo "== the same client asking again is not prompted twice"
reset
run "1_100"; run "1_100"
[ "$(ncalls)" = 1 ] && ok "one picker for two sessions from one client" || bad "picker ran $(ncalls) times"
grep -q '\[SELECTION\]0/screen:DP-1' "$work/out" && ok "replayed the selection verbatim" || bad "replay lost the selection"

echo
echo "== a client that was not there at consent time gets its own picker"
reset
run "1_100"
run "1_100 1_200"          # a second process opens a ScreenCast session
[ "$(ncalls)" = 2 ] && ok "new client was prompted" || bad "NEW CLIENT INHERITED CONSENT (picker ran $(ncalls) time(s))"

echo
echo "== a client asking alone after consent still gets its own picker"
reset
run "1_100"
run "1_200"                # the consenting client is gone; someone else asks
[ "$(ncalls)" = 2 ] && ok "unrelated client was prompted" || bad "UNRELATED CLIENT INHERITED CONSENT"

echo
echo "== clients disappearing does not force a re-prompt"
reset
run "1_100 1_300"
run "1_100"
[ "$(ncalls)" = 1 ] && ok "a shrinking client set still replays" || bad "re-prompted unnecessarily"

echo
echo "== consent is not replayed when the caller cannot be identified"
reset
run "1_100"
BUSCTL_FAIL=1 run "1_100"
[ "$(ncalls)" = 2 ] && ok "unidentifiable caller gets a picker" || bad "replayed to an unidentifiable caller"

echo
echo "== an expired selection is not replayed"
reset
run "1_100"
cache="$XDG_RUNTIME_DIR/xdph-share-picker.cache"
{ echo $(( $(date +%s) - 600 )); sed -n 2p "$cache"; sed -n 3p "$cache"; } > "$cache.new" && mv "$cache.new" "$cache"
run "1_100"
[ "$(ncalls)" = 2 ] && ok "expired selection re-prompts" || bad "replayed an expired selection"

echo
echo "== a cancelled picker invalidates the cache"
reset
run "1_100"
# A new client forces the picker to actually open; the user cancels it.
PICKER_STATUS=1 run "1_100 1_400" ; true
[ -f "$cache" ] && bad "cache survived a cancel" || ok "cancel cleared the cache"
# ...and the next caller is prompted rather than replayed.
before=$(ncalls); run "1_100"; after=$(ncalls)
[ "$after" -gt "$before" ] && ok "a cancel does not leave a replayable selection" || bad "replayed after a cancel"

echo
echo "== the xdph protocol is preserved"
reset
run "1_100"
grep -q '^\[SELECTION\]' "$work/out" && ok "stdout carries [SELECTION]" || bad "stdout lost the protocol line"

echo
[ "$fail" -eq 0 ] && { echo "share consent is scoped to the requesting client"; exit 0; }
exit 1
