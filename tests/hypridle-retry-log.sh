#!/bin/bash
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
launch="$work/hypridle-launch"
sed -e "s|^PATH=.*|PATH=$fixtures:/usr/bin:/bin; export PATH|" \
    -e "s|^HYPRIDLE_CANDIDATES=.*|HYPRIDLE_CANDIDATES=\"$fixtures/hypridle\"|" \
    -e "s|^POLICY=.*|POLICY=$policy|" "$src" > "$launch"
chmod +x "$launch"

export HYPRIDLE_LOG="$work/argv" HYPRIDLE_CONF_COPY="$work/handed.conf"
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" XDG_RUNTIME_DIR="$work/run"
mkdir -p "$XDG_RUNTIME_DIR"

retry() { # retry <rule> <exit|failed> <met|unmet>
    printf '[LOG] Retrying condition_cmd for rule %s\n' "$1"
    printf '[LOG] Running condition_cmd: /x/session-locked.sh\n'
    if [ "$2" = failed ]; then
        printf '[ERR] Failed to run condition_cmd: /x/session-locked.sh\n'
    else
        printf '[LOG] condition_cmd exited with %s\n' "$2"
    fi
    if [ "$3" = met ]; then
        printf '[LOG] Condition met, running /x/dpms-off-if-locked.sh\n'
    else
        printf '[LOG] Condition still not met, retrying in 10s\n'
    fi
}
idled() { # idled <rule> <exit>
    printf '[LOG] Idled: rule %s\n' "$1"
    printf '[LOG] Running condition_cmd: /x/session-locked.sh\n'
    printf '[LOG] condition_cmd exited with %s\n' "$2"
    printf '[LOG] condition_cmd blocked on-timeout, retrying in 10s\n'
}

{
    printf '[LOG] found 3 rules\n'
    idled aa 1
    idled bb 1
    for _ in 1 2 3 4 5; do retry aa 1 unmet; retry bb 1 unmet; done
    retry aa 124 unmet
    retry aa 124 unmet
    retry bb failed unmet
    retry bb failed unmet
    retry bb 1 unmet
    printf '[LOG] Inhibit locks: 1\n'
    retry aa 0 met
    printf '[LOG] Resumed: rule aa\n'
    idled aa 1
    retry aa 1 unmet
    printf '[LOG] Retrying condition_cmd for rule cc\n'
    printf '[LOG] Running condition_cmd: /x/session-locked.sh\n'
} > "$work/stdout"

{
    printf '[LOG] found 3 rules\n'
    idled aa 1
    idled bb 1
    retry aa 124 unmet
    retry bb failed unmet
    retry bb failed unmet
    retry bb 1 unmet
    printf '[LOG] Inhibit locks: 1\n'
    retry aa 0 met
    printf '[LOG] Resumed: rule aa\n'
    idled aa 1
    printf '[LOG] Retrying condition_cmd for rule cc\n'
    printf '[LOG] Running condition_cmd: /x/session-locked.sh\n'
} > "$work/expected"

echo "== retries that change nothing are dropped, everything else reaches the journal in order"
HYPRIDLE_STDOUT="$work/stdout" bash "$launch" > "$work/out" 2> "$work/err"
for _ in $(seq 50); do cmp -s "$work/out" "$work/expected" && break; sleep 0.1; done
if cmp -s "$work/out" "$work/expected"; then
    ok "output is exactly the state changes"
else
    diff "$work/expected" "$work/out" | head -20
    bad "filtered output differs from the expected state changes"
fi
before=$(wc -l < "$work/stdout"); after=$(wc -l < "$work/out")
[ "$after" -lt "$before" ] && ok "$before lines in, $after lines out" || bad "nothing dropped ($before -> $after)"
[ "$(grep -c 'condition_cmd exited with 1$' "$work/out")" -eq 4 ] \
    && ok "an unchanged exit 1 is logged once per idle period per rule" \
    || bad "exit 1 logged $(grep -c 'condition_cmd exited with 1$' "$work/out") times"
[ "$(grep -c '^\[ERR\]' "$work/out")" -eq 2 ] && ok "every ERR line survives" || bad "ERR lines dropped"
grep -q 'Condition met' "$work/out" && ok "the met transition survives" || bad "met transition dropped"
[ -s "$work/err" ] && { cat "$work/err"; bad "stderr noise"; } || ok "stderr untouched and silent"
[ "$(head -n1 "$HYPRIDLE_LOG")" = "-c $policy" ] && ok "hypridle still gets -c $policy" || bad "argv: $(head -n1 "$HYPRIDLE_LOG")"

echo
echo "== hypridle stays the exec'd main process and its lines arrive without buffering"
printf '[LOG] wayland done, registering dbus\n' > "$work/live"
: > "$work/out"
HYPRIDLE_STDOUT="$work/live" HYPRIDLE_HOLD=3 HYPRIDLE_PID="$work/pid" bash "$launch" > "$work/out" 2>/dev/null &
pid=$!
for _ in $(seq 20); do [ -s "$work/out" ] && break; sleep 0.1; done
grep -q 'registering dbus' "$work/out" && ok "a line reaches the journal while hypridle is still running" || bad "output held back by buffering"
[ "$(cat "$work/pid" 2>/dev/null)" = "$pid" ] && ok "hypridle runs as the launcher's pid $pid" || bad "hypridle pid $(cat "$work/pid" 2>/dev/null) is not the launcher's $pid"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

echo
[ "$fail" -eq 0 ] && { echo "hypridle retries log only on state change"; exit 0; }
exit 1
