#!/bin/bash
# The media module is one long-lived follower, not a 2 s poll: waybar runs
# waybar-mediaplayer.py once and reads a line per change. These cases run
# the script against a scripted playerctl and check what reaches waybar.
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

fixtures="$root/tests/fixtures/media-stream"
chmod +x "$fixtures/playerctl"
script="$root/dist/libexec/waybar-mediaplayer.py"
export MEDIA_ARGV_LOG="$work/argv" MEDIA_PIDFILE="$work/pid"

# run_follow <seconds> [env...]: run the script under the stub for a bounded
# time; its stdout lands in $out. timeout's SIGTERM is how waybar ends it.
out="$work/out"
run_follow() {
    local secs=$1; shift
    : > "$MEDIA_ARGV_LOG"
    env "$@" PATH="$fixtures:$PATH" timeout "$secs" python3 "$script" > "$out" 2> "$work/err"
}

echo "== the bar reads a stream: no interval, no exec-if, no timeout wrapper"
cfg="$root/dist/waybar/config.jsonc"
block=$(sed -n '/"custom\/media": {/,/^        }/p' "$cfg")
if printf '%s' "$block" | grep -qE '"interval"|"exec-if"|timeout [0-9]'; then
    printf '%s\n' "$block"
    bad "custom/media still polls"
else
    ok "custom/media has no interval, exec-if or timeout wrapper"
fi
printf '%s' "$block" | grep -q '"exec": "@LIBEXECDIR@/waybar-mediaplayer.py"' \
    && ok "exec is the follower script itself" \
    || bad "exec is not the follower script"

echo
echo "== the follower asks playerctl for a change-driven feed"
printf 'spotify\\tPlaying\\tA Band\\tSong One\n' > "$work/one.txt"
run_follow 1 MEDIA_SCRIPT="$work/one.txt"
argv=$(head -n1 "$MEDIA_ARGV_LOG")
printf '%s' "$argv" | grep -q -- '--follow' && ok "uses --follow" || bad "no --follow in: $argv"
printf '%s' "$argv" | grep -q '{{status}}' \
    && ok "the format names status, so play/pause re-emits" \
    || bad "format does not name status; a pause would never hide the module"
printf '%s' "$argv" | grep -q '%any' \
    && ok "every player is admitted (%any), ranked below the preferred ones" \
    || bad "players outside the preference list are never shown: $argv"
printf '%s' "$argv" | grep -q 'position' \
    && bad "position in the format makes playerctl tick every second" \
    || ok "no position in the format (that would be a 1 s tick)"

echo
echo "== each change becomes one line waybar can parse; hidden unless playing"
cat > "$work/seq.txt" <<'S'
spotify\tPlaying\tA Band\tSong One
spotify\tPaused\tA Band\tSong One
spotify\tPlaying\tA Band\tSong One
firefox\tPlaying\tSomeone\tA "quoted" <b>title</b>
firefox\tPlaying\t\tNo artist
firefox\tStopped\t\t

S
run_follow 2 MEDIA_SCRIPT="$work/seq.txt"
mapfile -t lines < "$out"
# 7 scripted lines, but a blank for "" after a blank for Stopped is a repeat
# and must be swallowed: 6 emitted.
[ "${#lines[@]}" -eq 6 ] && ok "one output line per state change, repeats swallowed (${#lines[@]})" \
    || { printf '  %q\n' "${lines[@]}"; bad "expected 6 output lines, got ${#lines[@]}"; }
n=0
for l in "${lines[@]}"; do
    n=$((n + 1))
    [ -z "$l" ] && continue
    printf '%s' "$l" | jq -e . >/dev/null 2>&1 || { printf '%s\n' "$l"; bad "line $n is not JSON"; }
done
ok "every non-blank line is valid JSON"
j() { printf '%s' "${lines[$1]}" | jq -r "$2"; }
play=$(printf '\357\201\213')   # U+F04B, the Nerd Font play glyph
[ "$(j 0 .text)" = "Song One - A Band $play" ] && ok "playing: title - artist and the play glyph" || bad "playing text: $(j 0 .text)"
[ "$(j 0 .class)" = playing ] && ok "playing: class playing" || bad "class: $(j 0 .class)"
[ "$(j 0 .alt)" = spotify ] && ok "playing: alt is the player" || bad "alt: $(j 0 .alt)"
[ -z "${lines[1]}" ] && ok "paused: blank line, module hidden" || bad "paused still shows: ${lines[1]}"
[ "$(j 3 .alt)" = firefox ] && ok "a change in another player is shown" || bad "alt: $(j 3 .alt)"
[ "$(j 3 .text)" = "A \"quoted\" <b>title</b> - Someone $play" ] \
    && ok "quotes and markup survive as data (waybar escapes markup itself)" \
    || bad "text mangled: $(j 3 .text)"
[ "$(j 4 .text)" = "No artist $play" ] && ok "no artist: no dangling separator" || bad "text: $(j 4 .text)"
[ -z "${lines[5]}" ] && ok "stopped: blank line" || bad "stopped still shows: ${lines[5]}"

echo
echo "== a dead follower is retried with backoff, never busy-looped"
# Shrink the delay in a copy rather than through the environment: the shipped
# script takes no knobs from the session.
slow="$work/mediaplayer-fast.py"
sed -e 's/^RETRY_DELAY = .*/RETRY_DELAY = 0.3/' -e 's/^RETRY_CAP = .*/RETRY_CAP = 0.3/' "$script" > "$slow"
: > "$MEDIA_ARGV_LOG"
MEDIA_EXIT=1 PATH="$fixtures:$PATH" timeout 1.2 python3 "$slow" > "$out" 2> "$work/err"
spawns=$(wc -l < "$MEDIA_ARGV_LOG")
if [ "$spawns" -ge 2 ] && [ "$spawns" -le 6 ]; then
    ok "playerctl exiting with an error was respawned $spawns times in 1.2 s (paced)"
else
    bad "expected 2-6 respawns in 1.2 s, saw $spawns"
fi
[ "$(grep -c '^$' "$out")" -ge 1 ] && ok "a lost feed blanks the module" || bad "nothing blanked after the feed died"

echo
echo "== no playerctl at all: hide once and stop, no respawn loop"
: > "$MEDIA_ARGV_LOG"
started=$(date +%s%N)
mkdir -p "$work/empty-bin"
py=$(command -v python3); to=$(command -v timeout)
PATH="$work/empty-bin" "$to" 5 "$py" "$script" > "$out" 2> "$work/err"; rc=$?
elapsed=$(( ($(date +%s%N) - started) / 1000000 ))
[ "$rc" -eq 0 ] && ok "exits 0" || bad "exit $rc without playerctl"
[ "$elapsed" -lt 2000 ] && ok "returned promptly (${elapsed} ms)" || bad "hung for ${elapsed} ms"
[ "$(cat "$out")" = "" ] && [ "$(wc -l < "$out")" -eq 1 ] && ok "exactly one blank line" || bad "unexpected output: $(cat "$out")"

echo
echo "== ending the script ends its follower"
run_follow 1 MEDIA_SCRIPT="$work/one.txt"
pid=$(cat "$MEDIA_PIDFILE" 2>/dev/null)
sleep 0.3
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    bad "playerctl (pid $pid) outlived the script"
else
    ok "no orphaned playerctl after SIGTERM"
fi

echo
echo "== the script is python, syntax-clean"
python3 -m py_compile "$script" && ok "py_compile" || bad "py_compile failed"

echo
[ "$fail" -eq 0 ] && { echo "media module streams"; exit 0; }
exit 1
