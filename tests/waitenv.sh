#!/bin/bash
[ -e /run/tripwire/hits ] || { [ "${HYPR_DE_SEALED-}" = build-root ] && [ ! -e /run/systemd/private ]; } || exec "$(dirname -- "$0")/run" "$0"
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }
check() {
    if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$4 (got '$1')"; fi
}

waiter="$root/dist/libexec/hypr-de-waitenv"
dropin="$root/dist/systemd/user/wayland-session-waitenv.service.d/hypr-de.conf"
work=$(mktemp -d) || exit 2
stop_all() {
    local p
    for p in "$work"/*/wpid; do [ -e "$p" ] && kill "$(cat "$p")" 2>/dev/null; done
    wait
}
trap 'stop_all; rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/runtime"

grep -q '^PATH=/usr/local/bin:/usr/bin:/bin; export PATH$' "$waiter" || {
    echo "hypr-de-waitenv must pin PATH to root-owned directories" >&2; exit 1; }
sed -e "s|^PATH=/usr/local/bin:/usr/bin:/bin;|PATH=$work/bin:/usr/bin:/bin;|" "$waiter" >"$work/waitenv"

cat >"$work/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$CASE/calls"
[ "$*" = "--user show-environment" ] || exit 1
echo "$EPOCHREALTIME" >>"$CASE/reads"
[ -e "$CASE/unreachable" ] && exit 1
if [ -s "$CASE/fail-reads" ]; then
    n=$(cat "$CASE/fail-reads")
    if [ "$n" -gt 0 ]; then echo $(( n - 1 )) >"$CASE/fail-reads"; exit 1; fi
fi
cat "$CASE/env"
EOF
cat >"$work/bin/busctl" <<'EOF'
#!/bin/sh
echo "busctl $*" >>"$CASE/calls"
[ "$*" = "--user get-property org.freedesktop.systemd1 /org/freedesktop/systemd1/unit/wayland_2dsession_2dwaitenv_2eservice org.freedesktop.systemd1.Service TimeoutStartUSec" ] || exit 1
[ -n "${UNIT_TIMEOUT_USEC-}" ] || exit 1
echo "t $UNIT_TIMEOUT_USEC"
EOF
chmod +x "$work/bin"/*

now_ms() { local t=${EPOCHREALTIME//[!0-9]/}; echo $(( t / 1000 )); }

# start <case> [VAR=value ...] [-- waiter args]: runs the waiter on the case's
# manager environment and records its pid, exit status and finish time.
# wpid is the waiter itself, so cleanup can stop it before its fakes go.
start() {
    local c="$work/$1" vars=() args=()
    shift
    mkdir -p "$c"
    [ -e "$c/env" ] || : >"$c/env"
    while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    args=("$@")
    (
        env -i HOME="$work" XDG_RUNTIME_DIR="$work/runtime" CASE="$c" "${vars[@]}" \
            bash "$work/waitenv" "${args[@]}" >"$c/out" 2>&1 &
        echo $! >"$c/wpid"
        wait $!
        echo $? >"$c/rc"
        now_ms >"$c/done"
    ) &
    echo $! >"$c/pid"
    now_ms >"$c/start"
}
publish() {
    local c="$work/$1"
    shift
    { cat "$c/env"; printf '%s\n' "$@"; } >"$c/env.new"
    mv "$c/env.new" "$c/env"
    now_ms >"$c/published"
}
seed() { mkdir -p "$work/$1"; local c=$1; shift; printf '%s\n' "$@" >"$work/$c/env"; }
running() { kill -0 "$(cat "$work/$1/pid")" 2>/dev/null && [ ! -e "$work/$1/rc" ] && echo running || echo exited; }
finish() {
    local n=0
    while [ ! -s "$work/$1/done" ] && [ "$n" -lt 2000 ]; do sleep 0.005; n=$(( n + 1 )); done
    cat "$work/$1/rc"
}
took() { echo $(( $(cat "$work/$1/done") - $(cat "$work/$1/${2:-start}") )); }
# read_us <case>: the case's manager reads so far, as microsecond stamps in $reads.
reads=()
read_us() {
    local r=() t
    reads=()
    [ -e "$work/$1/reads" ] && mapfile -t r <"$work/$1/reads"
    for t in "${r[@]}"; do reads+=("${t/./}"); done
}
# since_read <case> first|last: ms from the waiter's first or last read to its exit,
# which leaves out how long the waiter took to start under load.
since_read() {
    local i=0
    read_us "$1"
    [ "$2" = last ] && i=$(( ${#reads[@]} - 1 ))
    echo $(( $(cat "$work/$1/done") - reads[i] / 1000 ))
}
# await_reads <case> <n>: waits up to 5 s for n more reads than there are now.
await_reads() {
    local want end
    read_us "$1"
    want=$(( ${#reads[@]} + $2 ))
    end=$(( $(now_ms) + 5000 ))
    while read_us "$1"; (( ${#reads[@]} < want )); do
        (( $(now_ms) < end )) || return 1
        sleep 0.005
    done
}
# held <case>: "running" once the waiter has read twice more and not returned.
# The second read shows it acted on the first, which began after this call.
held() {
    if await_reads "$1" 2 && [ "$(running "$1")" = running ]; then echo running; else echo exited; fi
}

stock=(UWSM_WAIT_VARNAMES=HYPRLAND_INSTANCE_SIGNATURE UWSM_WAIT_VARNAMES_SETTLETIME=0)

echo "== the waiter returns well inside uwsm's 0.5 s check after the variables arrive"
lat=()
for i in 1 2 3 4 5 6 7 8 9; do
    seed "lat$i" XDG_CURRENT_DESKTOP=Hyprland
    start "lat$i" "${stock[@]}"
    await_reads "lat$i" 2
    publish "lat$i" WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=sig
    check "$(finish "lat$i")" 0 "run $i exits 0 once the variables are there" "run $i did not exit 0"
    lat+=("$(took "lat$i" published)")
done
median=$(printf '%s\n' "${lat[@]}" | sort -n | sed -n 5p)
echo "     latencies ms: ${lat[*]}"
check "$(( median <= 200 ))" 1 "the median latency is at most 200 ms (${median} ms)" \
    "the waiter took ${median} ms (median) to notice the variables"
grep -q '^All expected variables appeared in activation environment\.$' "$work/lat1/out"
check $? 0 "it logs the line the boot timeline marks as V" "the waiter no longer logs uwsm's V line"

echo
echo "== it never returns before every required variable is present"
start stage "UWSM_WAIT_VARNAMES=HYPRLAND_INSTANCE_SIGNATURE MY_VAR" UWSM_WAIT_VARNAMES_SETTLETIME=0
seed args WAYLAND_DISPLAY=wayland-1
start args UWSM_WAIT_VARNAMES_SETTLETIME=0 -- ARG_VAR
check "$(held stage)" running "nothing set: still waiting" "the waiter returned with nothing set"
publish stage XWAYLAND_DISPLAY=:0 WAYLAND_DISPLAY_OLD=x 'FOO=WAYLAND_DISPLAY=x' \
    "BAR=\$'line\\nWAYLAND_DISPLAY=x\\nHYPRLAND_INSTANCE_SIGNATURE=y\\nMY_VAR=z'" \
    'MY_VAR_2=x' ' HYPRLAND_INSTANCE_SIGNATURE=x'
check "$(held stage)" running "names that only contain or prefix the wanted ones do not count" \
    "a decoy name or value satisfied the wait"
publish stage WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=sig
check "$(held stage)" running "WAYLAND_DISPLAY and the signature alone do not end a wait for more" \
    "the waiter ignored the second variable in UWSM_WAIT_VARNAMES"
publish stage MY_VAR=
check "$(finish stage)" 0 "the last variable, even empty, ends the wait as in uwsm" "the waiter did not exit 0"
check "$(held args)" running "a variable named on the command line is waited for" \
    "the waiter ignored its command-line variable"
publish args ARG_VAR=1
check "$(finish args)" 0 "and its arrival ends the wait" "the waiter did not exit 0 once its argument arrived"
grep -q '^Still expecting:$' "$work/stage/out"
check $? 0 "it reports partial progress" "the waiter did not report the variables still missing"

echo
echo "== it filters the wait list as uwsm's filter_varnames does"
seed filter WAYLAND_DISPLAY=wayland-1
start filter "UWSM_WAIT_VARNAMES=SHELL _ PWD OLDWD 1A A-B A.B _1 B" UWSM_WAIT_VARNAMES_SETTLETIME=0 -- 'C D' X
check "$(held filter)" running "valid names still hold the wait" "the waiter dropped a valid name"
publish filter _1=1 B=2 X=3
check "$(finish filter)" 0 "the shell's own names and illegal names are never waited for" \
    "the waiter waited for a dropped or illegal name"
for v in 1A A-B A.B 'C D'; do
    grep -qxF "Encountered illegal var \"$v\"." "$work/filter/out"
    check $? 0 "an illegal name ($v) is reported in uwsm's words" "the waiter did not report the illegal name $v"
done
check "$(grep -c -e SHELL -e PWD -e OLDWD -e '"_"' "$work/filter/out")" 0 \
    "the shell's own names are dropped silently" "the waiter reported a shell name it should drop silently"
check "$(grep -A1 -x 'Still expecting:' "$work/filter/out" | sed -n 2p)" "  X, _1, B" \
    "_1 and B pass the name pattern and are waited for" "the waiter's wait list differs from uwsm's"

echo
echo "== it honours the settle time"
start settle UWSM_WAIT_VARNAMES_SETTLETIME=0.4
publish settle WAYLAND_DISPLAY=wayland-1
check "$(finish settle)" 0 "exits 0 after the settle" "the waiter failed with a settle set"
t=$(since_read settle last)
check "$(( t >= 400 && t < 1000 ))" 1 "waits the 0.4 s settle (${t} ms)" "a 0.4 s settle took ${t} ms"
seed settle-default WAYLAND_DISPLAY=wayland-1
start settle-default
seed settle-bad WAYLAND_DISPLAY=wayland-1
start settle-bad UWSM_WAIT_VARNAMES_SETTLETIME=soon
for c in settle-default settle-bad; do
    finish "$c" >/dev/null
    t=$(since_read "$c" last)
    check "$(( t >= 200 && t < 800 ))" 1 "$c falls back to uwsm's 0.2 s (${t} ms)" "$c took ${t} ms, not uwsm's 0.2 s"
done
grep -q 'invalid value "soon"' "$work/settle-bad/out"
check $? 0 "an invalid settle is reported" "the waiter took an invalid settle silently"

echo
echo "== it times out as uwsm's waitenv does, and fails closed"
start to-unit UNIT_TIMEOUT_USEC=1000000 UWSM_WAIT_VARNAMES_TIMEOUT=30
start to-env UWSM_WAIT_VARNAMES_TIMEOUT=1
start to-bad UWSM_WAIT_VARNAMES_TIMEOUT=soon
start to-forever UNIT_TIMEOUT_USEC=18446744073709551615 UWSM_WAIT_VARNAMES_TIMEOUT=1
for c in to-unit to-env; do
    check "$(finish "$c")" 1 "$c: no variables by the timeout exits 1" "$c: the waiter did not fail on timeout"
    lo=$(took "$c") t=$(since_read "$c" first)
    check "$(( lo >= 3900 && t < 5500 ))" 1 "$c: gives up after 1 s plus uwsm's 3 s buffer (${t} ms)" \
        "$c: gave up after ${t} ms (${lo} ms from launch), not 1 s plus 3 s"
done
check "$(running to-bad)" running "an invalid timeout falls back to uwsm's 30 s" "an invalid timeout ended the wait early"
check "$(running to-forever)" running "the unit's infinite timeout wins over the variable" \
    "an infinite TimeoutStartSec did not win over UWSM_WAIT_VARNAMES_TIMEOUT"
grep -qxF 'Still waiting for variables in activation environment, nearing timeout:' "$work/to-env/out"
check $? 0 "it warns near the timeout in uwsm's words" "the waiter did not warn near the timeout"
grep -qxF 'Timed out waiting for variables in activation environment:' "$work/to-env/out"
check $? 0 "it reports the timeout in uwsm's words" "the waiter did not report the timeout"
grep -qxF 'Expected integer value from UWSM_WAIT_VARNAMES_TIMEOUT var, got: soon' "$work/to-bad/out"
check $? 0 "an invalid timeout is reported in uwsm's words" "the waiter did not report the invalid timeout"
check "$(grep -c -e 'Warning!' -e 'Error!' "$work"/*/out | grep -vc ':0$')" 0 \
    "no line carries a prefix uwsm does not print" "the waiter still prefixes its lines"
kill "$(cat "$work/to-bad/wpid")" "$(cat "$work/to-forever/wpid")" 2>/dev/null

echo
echo "== it rides out brief read failures, fails when the manager stays unreadable, and changes nothing"
seed blip WAYLAND_DISPLAY=wayland-1
echo 2 >"$work/blip/fail-reads"
start blip UWSM_WAIT_VARNAMES_SETTLETIME=0
check "$(finish blip)" 0 "two failed reads then a good one exit 0" "the waiter gave up on a brief read failure"
check "$(grep -c 'show-environment' "$work/blip/calls")" 3 "it read three times" "the waiter read a different number of times"
t=$(since_read blip first)
check "$(( t < 2000 ))" 1 "and returned inside the 2 s grace (${t} ms)" "a brief read failure cost ${t} ms"
seed down WAYLAND_DISPLAY=wayland-1
: >"$work/down/unreachable"
start down
check "$(finish down)" 1 "a manager that stays unreadable exits 1" "the waiter did not fail on an unreadable manager"
t=$(since_read down first)
check "$(( t >= 1900 && t < 3000 ))" 1 "after 2 s of failed reads, well inside the timeout (${t} ms)" \
    "the waiter gave up on an unreadable manager after ${t} ms, not 2 s"
calls=$(cat "$work"/*/calls | sort -u | paste -sd'|' -)
check "${calls}" \
    "busctl --user get-property org.freedesktop.systemd1 /org/freedesktop/systemd1/unit/wayland_2dsession_2dwaitenv_2eservice org.freedesktop.systemd1.Service TimeoutStartUSec|systemctl --user show-environment" \
    "it only reads the manager" "the waiter called something other than the two reads"
check "$(find "$work/runtime" -mindepth 1 | wc -l)" 0 "it writes nothing to uwsm's runtime dir or cleanup list" \
    "the waiter wrote under XDG_RUNTIME_DIR"

echo
echo "== it fails closed when its clock cannot be read"
grep -q '</proc/uptime$' "$work/waitenv" || { bad "the waiter no longer reads /proc/uptime; update this check"; exit 1; }
cp "$work/waitenv" "$work/waitenv.ok"
sed -i 's|</proc/uptime$|</nonexistent/uptime|' "$work/waitenv"
start noclock UWSM_WAIT_VARNAMES_TIMEOUT=1
check "$(finish noclock)" 1 "an unreadable clock exits 1 with nothing present" \
    "the waiter released the target when its clock failed"
mv "$work/waitenv.ok" "$work/waitenv"

echo
echo "== it fails closed when its settle pause fails"
mkdir -p "$work/badsleep"
cat >"$work/badsleep/sleep" <<EOF
#!/bin/sh
[ "\$1" = 0.37 ] && kill -KILL \$\$
exec $(command -v sleep) "\$@"
EOF
chmod +x "$work/badsleep/sleep"
cp "$work/waitenv" "$work/waitenv.ok"
sed -i "s|^PATH=$work/bin:|PATH=$work/badsleep:$work/bin:|" "$work/waitenv"
grep -q "^PATH=$work/badsleep:" "$work/waitenv" || { bad "could not put the failing sleep on the waiter's PATH"; exit 1; }
seed killed WAYLAND_DISPLAY=wayland-1
start killed UWSM_WAIT_VARNAMES_SETTLETIME=0.37
check "$(finish killed)" 1 "a settle pause that is killed exits 1" \
    "the waiter released the target when its settle pause failed"
mv "$work/waitenv.ok" "$work/waitenv"

echo
echo "== it checks every 10 ms at first and backs off to 100 ms after 2 s"
start slow UWSM_WAIT_VARNAMES_SETTLETIME=0
late_reads() {
    local t
    late=0
    for t in "${reads[@]}"; do (( t - reads[0] >= 3000000 )) && late=$(( late + 1 )); done
}
end=$(( $(now_ms) + 15000 ))
while read_us slow; late_reads; (( late < 4 )); do
    (( $(now_ms) < end )) || break
    sleep 0.05
done
fast_min=999999999 slow_min=999999999 slow_n=0
for (( i = 1; i < ${#reads[@]}; i++ )); do
    a=$(( reads[i-1] - reads[0] )) b=$(( reads[i] - reads[0] )) g=$(( reads[i] - reads[i-1] ))
    (( b <= 2000000 && g < fast_min )) && fast_min=$g
    if (( a >= 3000000 && slow_n < 3 )); then
        slow_n=$(( slow_n + 1 ))
        (( g < slow_min )) && slow_min=$g
    fi
done
check "$(( fast_min < 100000 ))" 1 "a gap between reads in the first 2 s is under 100 ms ($(( fast_min / 1000 )) ms)" \
    "no gap between reads in the first 2 s was under 100 ms (shortest $(( fast_min / 1000 )) ms)"
check "$(( slow_n == 3 && slow_min >= 90000 ))" 1 \
    "the first three gaps after 3 s are each at least 90 ms (shortest $(( slow_min / 1000 )) ms)" \
    "after 3 s, ${slow_n} gaps, the shortest $(( slow_min / 1000 )) ms"
publish slow WAYLAND_DISPLAY=wayland-1
check "$(finish slow)" 0 "and still exits 0 once the variables arrive" "the slow waiter did not exit 0"
t=$(took slow published)
check "$(( t < 1000 ))" 1 "within 1 s, under load too (${t} ms)" "the slow waiter took ${t} ms"

echo
echo "== the drop-in replaces waitenv's ExecStart with the waiter alone"
verify() {
    local d="$work/units-$1"
    mkdir -p "$d/wayland-session-waitenv.service.d" "$work/runtime-$1"
    printf '%s\n' '[Unit]' 'Description=Wait for WAYLAND_DISPLAY and other variables' \
        '[Service]' 'Type=oneshot' 'ExecStart=/nonexistent/uwsm aux waitenv' \
        >"$d/wayland-session-waitenv.service"
    sed "s|@LIBEXECDIR@|$root/dist/libexec|g" >"$d/wayland-session-waitenv.service.d/hypr-de.conf"
    env -i PATH=/usr/bin:/bin HOME="$work" XDG_RUNTIME_DIR="$work/runtime-$1" SYSTEMD_UNIT_PATH="$d:" \
        systemd-analyze --user verify --man=no "$d/wayland-session-waitenv.service" 2>&1
}
command -v systemd-analyze >/dev/null || { bad "systemd-analyze is needed to load the drop-in"; exit 1; }
out=$(verify shipped <"$dropin")
check "$?:${out}" "0:" "systemd loads the shipped drop-in with no warning and runs only the waiter" \
    "systemd-analyze verify rejected the drop-in: ${out}"
for m in "no header:/^\[Service\]$/d" "wrong section:s/^\[Service\]$/[Unit]/" "no reset:/^ExecStart=$/d"; do
    name=${m%%:*}
    sed "${m#*:}" "$dropin" | verify "${name// /-}" >/dev/null
    check "$?" 1 "a drop-in with ${name} fails the check" "a drop-in with ${name} passed verify"
done

exit "$fail"
