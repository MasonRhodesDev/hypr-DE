#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixtures="$root/tests/fixtures/lock-policy"
src="$root/dist/libexec/lock-cmd.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export LOCK_POLICY_LOG="$work/log"
export PATH="$fixtures:$PATH"
export XDG_RUNTIME_DIR="$work"
marker="$work/hypr-de-lock-failed"
lock_conf="$work/lock.conf"

# Policy is baked into the script (a root-owned /etc file is the only thing
# that may change it -- see BAR-017), so the suite builds variants by
# rewriting those constants rather than by setting environment variables.
# It also keeps the run hermetic: without an explicit fallback list the real
# hyprlock on the test machine would be found, and would lock the screen.
mk_lock() {  # mk_lock [fallbacks] [failsafe]
    sed -e "s|^LOCK_CONF=.*|LOCK_CONF=$lock_conf|" \
        -e "s|^FAILSAFE=.*|FAILSAFE=${2:-terminate}|" \
        -e "s|^FALLBACKS=.*|FALLBACKS='${1:-}'|" \
        -e "s|^VERIFY_TRIES=.*|VERIFY_TRIES=1|" \
        "$src" > "$work/lock-cmd.sh"
    chmod +x "$work/lock-cmd.sh"
}

# The libexec helpers pin PATH to root-owned directories (BAR-017), so the
# suite runs copies whose pin is redirected at the fixtures, exactly as
# mk_lock rewrites lock-cmd.sh's constants.
mk_libexec() {  # mk_libexec <script>
    grep -q '^PATH=/usr/local/bin:/usr/bin:/bin; export PATH$' "$root/dist/libexec/$1" || {
        echo "$1 must pin PATH to root-owned directories" >&2; exit 1; }
    sed -e "s|^PATH=.*|PATH=$fixtures:/usr/bin:/bin; export PATH|" \
        "$root/dist/libexec/$1" > "$work/$1"
    chmod +x "$work/$1"
}
status=0
run_lock() {
    status=0
    "$work/lock-cmd.sh" "$@" 2>>"$work/stderr" || status=$?
}
assert_log() {
    expected=$1
    actual=$(cat "$LOCK_POLICY_LOG")
    [ "$actual" = "$expected" ] || {
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        exit 1
    }
}
assert_status() {
    [ "$status" = "$1" ] || { echo "expected exit $1, got $status" >&2; exit 1; }
}
assert_marker() {
    if [ "$1" = yes ] && [ ! -e "$marker" ]; then
        echo "expected the lock-failure marker to exist" >&2; exit 1
    fi
    if [ "$1" = no ] && [ -e "$marker" ]; then
        echo "expected no lock-failure marker" >&2; exit 1
    fi
}

# --- routing ---------------------------------------------------------------
mk_lock
: > "$LOCK_POLICY_LOG"
run_lock
assert_log 'vigil-lock:--wait --no-warn
logind-idle-control:disable
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'

: > "$LOCK_POLICY_LOG"
VIGIL_IDLE_WARNING_SECONDS=7 run_lock --idle
assert_log 'vigil-lock:--wait --warn 7'

: > "$LOCK_POLICY_LOG"
LOCK_POLICY_VIGIL_STATUS=3 run_lock --idle
assert_status 0
assert_log 'vigil-lock:--wait --warn 10'
assert_marker no

# --- fail-closed escalation (issue #10) ------------------------------------

# The transient scope cannot start: fall back to an unscoped locker rather
# than returning to hypridle with the session wide open.
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_SCOPE_STATUS=1 run_lock
assert_status 0
assert_log 'systemd-run:scope-failed
vigil-lock:--wait --no-warn
logind-idle-control:disable
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'
assert_marker no

# vigil-lock itself is broken: use any other installed locker before giving up.
mk_lock 'swaylock -f'
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_VIGIL_STATUS=1 \
    PATH="$root/tests/fixtures/lock-policy-fallback:$PATH" run_lock
assert_status 0
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
swaylock:-f
logind-idle-control:disable
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'
assert_marker no

# Nothing can lock: terminate the session instead of handing back an exposed
# desktop that hypridle is about to blank into looking locked.
mk_lock
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_VIGIL_STATUS=1 run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'
assert_marker yes

# ...unless the operator opted out, in which case the session stays up but is
# marked failed so nothing disguises it as locked.
mk_lock '' warn
: > "$LOCK_POLICY_LOG"
rm -f "$marker"
LOCK_POLICY_VIGIL_STATUS=1 run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn'
assert_marker yes

# A later successful lock clears the marker.
: > "$LOCK_POLICY_LOG"
run_lock
assert_status 0
assert_marker no

# --- the failsafe is not disableable from the session (BAR-017) ------------
mk_lock
: > "$LOCK_POLICY_LOG"
rm -f "$marker" "$lock_conf"
HYPR_DE_LOCK_FAILSAFE=warn HYPR_DE_LOCK_FALLBACKS='true' \
    LOCK_POLICY_VIGIL_STATUS=1 run_lock
assert_status 1
assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'

# A policy file the session can write is ignored, whoever wrote it. The build
# may run this suite as root (rpm %check does), and root cannot write a
# file it does not own -- so hand it to nobody to make the case expressible.
: > "$LOCK_POLICY_LOG"
: > "$work/stderr"
rm -f "$marker"
printf 'failsafe=warn\n' > "$lock_conf"
if [ "$(id -u)" -eq 0 ]; then
    chown 65534:65534 "$lock_conf" 2>/dev/null \
        || chown nobody:nobody "$lock_conf" 2>/dev/null \
        || chown nobody "$lock_conf" 2>/dev/null || true
fi
if [ "$(stat -c '%u' "$lock_conf")" != 0 ]; then
    LOCK_POLICY_VIGIL_STATUS=1 run_lock
    assert_status 1
    assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn
loginctl:terminate-session 7'
    grep -q "must be owned by root" "$work/stderr" || {
        echo "expected a warning that the policy file was ignored" >&2; exit 1
    }
else
    echo "skip: cannot create a non-root-owned policy file in this environment"
fi

# The same file, when root owns it, is honoured -- it is the file's owner
# that matters, not the caller's, which is the real deployment shape: a
# root-owned /etc file read by an ordinary user session.
if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
    printf '# operator policy\nfailsafe = warn\n' > "$lock_conf"
    if [ "$(id -u)" -eq 0 ]; then chown 0:0 "$lock_conf"; else sudo -n chown 0:0 "$lock_conf"; fi
    chmod 644 "$lock_conf" 2>/dev/null || sudo -n chmod 644 "$lock_conf"
    : > "$LOCK_POLICY_LOG"
    : > "$work/stderr"
    rm -f "$marker"
    LOCK_POLICY_VIGIL_STATUS=1 run_lock
    cp "$work/stderr" "$work/stderr.tail"
    assert_status 1
    assert_log 'vigil-lock:--wait --no-warn
vigil-lock:--wait --no-warn'
    grep -q "must be owned by root" "$work/stderr.tail" 2>/dev/null && {
        echo "root-owned policy file was still rejected" >&2; exit 1; }
    echo "operator policy honoured when root owns it (spaced syntax parsed)"
fi
rm -f "$lock_conf" 2>/dev/null || sudo -n rm -f "$lock_conf"

# --- an intentional lock releases the idle inhibitor ----------------------
# Locking on purpose says "I am done with this session", so a held idle
# inhibitor must not then keep the screen lit all night. The idle path is
# NOT intentional: it fires because the user walked away, and an inhibitor
# is precisely the signal that they meant the session to stay awake.
: > "$LOCK_POLICY_LOG"
run_lock
assert_log 'vigil-lock:--wait --no-warn
logind-idle-control:disable
hyprctl:dispatch hl.dsp.dpms({ action = '\''on'\'' })'

: > "$LOCK_POLICY_LOG"
run_lock --sleep
assert_log 'vigil-lock:--wait --no-warn
logind-idle-control:disable'

: > "$LOCK_POLICY_LOG"
run_lock --idle
assert_log 'vigil-lock:--wait --warn 10'

# A failing or absent inhibitor CLI must never fail the lock.
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_INHIBIT_STATUS=1 run_lock
assert_status 0

# A wedged toggle daemon must not delay a lock either. hypridle holds its
# logind sleep inhibitor until before_sleep_cmd returns, so an unbounded
# release call here postpones the suspend itself.
started=$(date +%s)
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_INHIBIT_HANG=1 run_lock --sleep
assert_status 0
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 15 ] || {
    echo "a wedged toggle daemon delayed the lock by ${elapsed}s; the release must be bounded" >&2
    exit 1; }

# --- the locked-screen listener: compositor truth, never a hint ----------
# hypridle.conf's input-idle listener ignores inhibitors, so its condition is
# the only thing keeping it from blanking an unlocked, inhibited session 30 s
# into a film. It must follow the compositor lock, not logind's LockedHint (a
# hint can outlive its locker).
mk_libexec session-locked.sh
mk_libexec dpms-off-if-locked.sh
LOCK_POLICY_COMPOSITOR_LOCKED=true "$work/session-locked.sh" || {
    echo "session-locked.sh must pass while the compositor is locked" >&2; exit 1; }
if LOCK_POLICY_COMPOSITOR_LOCKED=false LOCK_POLICY_LOCKED_HINT=yes "$work/session-locked.sh"; then
    echo "session-locked.sh: a stale LockedHint must not authorise a blank" >&2; exit 1
fi

# The user's own idle inhibitor defers the blank; nothing else can, because
# the listener ignores hypridle's inhibitor accounting entirely.
if LOCK_POLICY_COMPOSITOR_LOCKED=true LOCK_POLICY_INHIBIT_ENABLED=1 "$work/session-locked.sh"; then
    echo "session-locked.sh: the user's idle inhibitor must defer the blank" >&2; exit 1
fi
LOCK_POLICY_COMPOSITOR_LOCKED=true LOCK_POLICY_INHIBIT_ENABLED=0 "$work/session-locked.sh" || {
    echo "session-locked.sh must blank a locked screen with the inhibitor off" >&2; exit 1; }

# A wedged toggle daemon must not stall the condition. hypridle runs
# condition_cmd through CProcess::runSync, which waits for the child to
# exit with no deadline of its own, on the same single loop that drives
# DPMS, the idle lock, unlock and sleep inhibits -- so a hang here freezes
# the session's whole idle machinery, not just this check. The script
# imposes its own bound and degrades to "blank as if no toggle": the
# compositor lock is the security invariant, the toggle is a convenience.
started=$(date +%s)
if LOCK_POLICY_COMPOSITOR_LOCKED=true LOCK_POLICY_INHIBIT_HANG=1 "$work/session-locked.sh"; then
    :
else
    echo "session-locked.sh: a wedged toggle daemon must degrade to blanking" >&2; exit 1
fi
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 10 ] || {
    echo "session-locked.sh waited ${elapsed}s on a wedged daemon; it must bound the call" >&2
    exit 1; }

# With no toggle installed at all, nothing was chosen, so a locked screen
# blanks. The PATH here carries ONLY what the script needs and no system
# directory: on a machine where logind-idle-control is genuinely installed
# -- every real deployment, and this one -- a /usr/bin fallback would still
# resolve it and the `command -v` guard would never be exercised.
mkdir -p "$work/no-toggle"
cp "$fixtures/hyprctl" "$work/no-toggle/hyprctl"
cp "$(command -v timeout)" "$work/no-toggle/timeout"
sed -e "s|^PATH=.*|PATH=$work/no-toggle; export PATH|" \
    "$root/dist/libexec/session-locked.sh" > "$work/session-locked-no-toggle.sh"
chmod +x "$work/session-locked-no-toggle.sh"
LOCK_POLICY_COMPOSITOR_LOCKED=true "$work/session-locked-no-toggle.sh" || {
    echo "session-locked.sh must blank when no toggle is installed" >&2; exit 1; }
# NOTE: this pins the behaviour, not the `command -v` guard that implements
# it. Removing the guard is an equivalent mutant: `timeout 2
# logind-idle-control status 2>/dev/null` on an absent binary yields the
# same empty stdout as never calling it, because the exec failure goes to
# the stderr this script discards. The guard earns its place by avoiding a
# fork+exec on every retry, which is a cost argument, not one a black-box
# test can make. Do not claim this case kills that mutation.

# A wedged compositor must not stall either script, for the same reason a
# wedged toggle daemon must not: both run on hypridle's single loop.
started=$(date +%s)
LOCK_POLICY_COMPOSITOR_HANG=1 "$work/session-locked.sh" && {
    echo "session-locked.sh: an unanswered compositor must not authorise a blank" >&2; exit 1; }
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_HANG=1 "$work/dpms-off-if-locked.sh"
assert_log ''
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 15 ] || {
    echo "a wedged compositor stalled the scripts for ${elapsed}s; both must bound it" >&2
    exit 1; }
# The on-timeout re-checks the lock itself: safe even without condition_cmd.
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_LOCKED=true "$work/dpms-off-if-locked.sh"
assert_log 'hyprctl:dispatch hl.dsp.dpms({ action = '\''off'\'' })'
: > "$LOCK_POLICY_LOG"
LOCK_POLICY_COMPOSITOR_LOCKED=false LOCK_POLICY_LOCKED_HINT=yes "$work/dpms-off-if-locked.sh"
assert_log ''
# A hyprctl planted earlier in the caller's PATH is never consulted: the
# unmodified script resets PATH before asking the compositor.
mkdir -p "$work/planted"
printf '#!/bin/sh\necho true\n' > "$work/planted/hyprctl"
chmod +x "$work/planted/hyprctl"
# (Empty instance signature: the real hyprctl it then finds must fail, not
# answer for whatever compositor the developer is sitting in.)
if PATH="$work/planted:$PATH" HYPRLAND_INSTANCE_SIGNATURE='' LOCK_POLICY_COMPOSITOR_LOCKED=true \
    "$root/dist/libexec/session-locked.sh" 2>/dev/null; then
    echo "session-locked.sh consulted a PATH-planted hyprctl" >&2; exit 1
fi

# --- the listener wiring is structural, not a single grep ------------------
conf="$root/dist/hypr/hypridle.conf"
# Exactly one listener ignores hypridle's inhibitor accounting -- the
# locked-screen blanker. That accounting covers three sources: the user's
# deliberate logind toggle, the freedesktop ScreenSaver D-Bus API, and
# Wayland surface inhibitors that video players and browsers set on their
# own. A locked screen must not be held lit by the latter two, so the
# listener ignores them all and session-locked.sh re-admits the one the
# user actually chose.
[ "$(grep -cE '^[[:space:]]*ignore_inhibit=true$' "$conf")" = 1 ] || {
    echo "hypridle.conf: exactly one listener may ignore inhibitors" >&2; exit 1; }
block=$(awk '/^listener \{/{inb=1;b="";next} inb&&/^\}/{inb=0; if (b ~ /session-locked\.sh/) print b; next} inb{b=b $0 "\n"}' "$conf")
for want in 'timeout=30' 'condition_cmd=@LIBEXECDIR@/session-locked.sh' 'condition_retry=' \
            'on-timeout=@LIBEXECDIR@/dpms-off-if-locked.sh'; do
    printf '%s' "$block" | grep -q "^  $want" || {
        echo "hypridle.conf: the locked-screen listener lost '$want'" >&2; exit 1; }
done
# No raw DPMS-off anywhere in the config -- not an on-timeout, not an
# on-resume, not after_sleep_cmd. The only blank in the session goes
# through the lock-checking script, so a literal off dispatch here is a
# second blanker by definition.
if grep -F "action = 'off'" "$conf" | grep -q .; then
    echo "hypridle.conf: a raw dpms-off dispatch bypasses the lock checks" >&2; exit 1
fi
# Every command hypridle can run is pinned as a set, matched with leading
# whitespace stripped: counting one exact line let a re-added blanker sit
# beside it, and a differently-indented or on-resume-mounted script slipped
# past a check that only read `on-timeout=` at exactly two spaces.
want_cmds='after_sleep_cmd=hyprctl dispatch "hl.dsp.dpms({ action = '"'"'on'"'"' })"
before_sleep_cmd=@LIBEXECDIR@/lock-cmd.sh --sleep
lock_cmd=@LIBEXECDIR@/lock-cmd.sh
on-resume=@LIBEXECDIR@/idle-suspend.sh --cancel
on-resume=hyprctl dispatch "hl.dsp.dpms({ action = '"'"'on'"'"' })"
on-timeout=@LIBEXECDIR@/dpms-off-if-locked.sh
on-timeout=@LIBEXECDIR@/idle-suspend.sh
on-timeout=@LIBEXECDIR@/lock-cmd.sh --idle'
got_cmds=$(sed -n 's/^[[:space:]]*\(on-timeout\|on-resume\|after_sleep_cmd\|before_sleep_cmd\|lock_cmd\)=/\1=/p' \
    "$conf" | LC_ALL=C sort)
[ "$got_cmds" = "$want_cmds" ] || {
    echo "hypridle.conf: the set of commands hypridle runs changed" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$want_cmds" "$got_cmds" >&2
    exit 1; }

# --- Idle suspend: a REQUEST to hyprstate, never a direct suspend -----------
# The 900 s listener asks hyprstate and nothing else; idle-suspend.sh is the
# bridge, and hyprstate owns grace, lock proof, cancellation and Suspend().
mk_libexec idle-suspend.sh
: > "$LOCK_POLICY_LOG"
"$work/idle-suspend.sh"
assert_log 'hyprstate:suspend request'
: > "$LOCK_POLICY_LOG"
"$work/idle-suspend.sh" --cancel
assert_log 'hyprstate:suspend cancel'
# Absent hyprstate is a silent no-op, not an error every idle period. Reuse
# the no-toggle dir (hyprctl + timeout only, no hyprstate) built above.
: > "$LOCK_POLICY_LOG"
sed -e "s|^PATH=.*|PATH=$work/no-toggle; export PATH|" \
    "$root/dist/libexec/idle-suspend.sh" > "$work/idle-suspend-no-hyprstate.sh"
chmod +x "$work/idle-suspend-no-hyprstate.sh"
"$work/idle-suspend-no-hyprstate.sh" || {
    echo "idle-suspend.sh must exit 0 when hyprstate is absent" >&2; exit 1; }
if [ -s "$LOCK_POLICY_LOG" ]; then
    echo "idle-suspend.sh ran something with hyprstate absent" >&2; exit 1
fi
# The suspend listener keeps its 900 s timeout and --cancel on resume, and
# MUST NOT ignore inhibitors -- a suspend that ignored them is the regression
# this listener exists to avoid (unlike the locked-screen blanker above).
sblock=$(awk '/^listener \{/{inb=1;b="";next} inb&&/^\}/{inb=0; if (b ~ /idle-suspend\.sh/) print b; next} inb{b=b $0 "\n"}' "$conf")
for want in 'timeout=900' 'on-timeout=@LIBEXECDIR@/idle-suspend.sh' \
            'on-resume=@LIBEXECDIR@/idle-suspend.sh --cancel'; do
    printf '%s' "$sblock" | grep -q "^  $want" || {
        echo "hypridle.conf: the idle-suspend listener lost '$want'" >&2; exit 1; }
done
if printf '%s' "$sblock" | grep -qE '^[[:space:]]*ignore_inhibit'; then
    echo "hypridle.conf: the idle-suspend listener must honor inhibitors" >&2; exit 1
fi

# --- one blanker, and it blanks only a locked compositor -------------------
# The locked listener is the session's only DPMS-off. A blank must follow
# the compositor lock and nothing else: not logind's LockedHint (a hint
# outlives a locker that died) and never an unlocked session, whose dark
# screen would be indistinguishable from a locked one.
blanker() {  # blanker <compositor-locked> <hint>; echoes locked|none
    : > "$LOCK_POLICY_LOG"
    LOCK_POLICY_COMPOSITOR_LOCKED=$1 LOCK_POLICY_LOCKED_HINT=$2 "$work/session-locked.sh" \
        && LOCK_POLICY_COMPOSITOR_LOCKED=$1 LOCK_POLICY_LOCKED_HINT=$2 "$work/dpms-off-if-locked.sh"
    if [ -s "$LOCK_POLICY_LOG" ]; then echo locked; else echo none; fi
    : > "$LOCK_POLICY_LOG"
}
for case in "true yes locked" "true no locked" "false no none" "false yes none"; do
    set -- $case
    got=$(blanker "$1" "$2")
    [ "$got" = "$3" ] || {
        echo "compositor_locked=$1 hint=$2: expected the $3 listener to blank, got $got" >&2
        exit 1; }
done

# --- an upgrade must not leave a stale idle policy running ----------------
# hypridle reads hypridle.conf once at startup and never watches it, so a
# package that rewrites the idle policy is inert until something restarts
# it. On 2026-08-26 that left a four-day-old hypridle with no locked-screen
# listener at all, on a machine whose packages were fully up to date.
#
# Run against a fixture with runuser/id/stat stubbed, the way
# privacy-privilege.sh already exercises the sibling. Grepping the source
# for the strings it ought to contain proves nothing: a comment mentioning
# try-restart satisfies a grep for try-restart.
restarter="$root/dist/libexec/hypr-de-restart-session-units"
[ -x "$restarter" ] || {
    echo "the post-transaction unit restarter is missing or not executable" >&2; exit 1; }

rfix="$work/runfix"; mkdir -p "$rfix/1000/systemd"
rhelper="$work/restarter"
sed -e "s|/run/user/\*|$rfix/*|" -e "s|\${run#/run/user/}|\${run#$rfix/}|" \
    "$restarter" > "$rhelper"
chmod +x "$rhelper"
grep -q "$rfix" "$rhelper" || {
    echo "the restarter fixture rewrite did not take; the cases below would pass vacuously" >&2
    exit 1; }

rbin="$work/rbin2"; mkdir -p "$rbin"
# The stubs EXECUTE rather than fake: runuser drops its own arguments and
# runs the command, so the script's real logic -- including the verdict it
# folds into `sh -c` -- runs against stubbed systemctl and hyprctl. A stub
# that answered on the script's behalf would test the mock, not the script,
# and that is exactly how a lock guard that can never fire got through.
cat > "$rbin/runuser" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$RESTART_OUT"
while [ $# -gt 0 ]; do
    case "$1" in --) shift; break ;; *) shift ;; esac
done
exec "$@"
STUB
cat > "$rbin/hyprctl" <<'STUB'
#!/bin/sh
# The real hyprctl refuses without a signature: prints to stdout, exits 1.
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || {
    echo "HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)"; exit 1; }
[ "${FIXTURE_HYPRCTL_BROKEN:-0}" = 1 ] && { echo "error"; exit 1; }
[ "$1" = locked ] && { printf '%s\n' "${FIXTURE_LOCKED:-false}"; exit 0; }
exit 0
STUB
cat > "$rbin/systemctl" <<'STUB'
#!/bin/sh
for a in "$@"; do case "$a" in
    show) printf '%s\n' "$([ -f "$RESTART_OUT.did" ] && echo 222 || echo 111)"; exit 0 ;;
    try-restart) : > "$RESTART_OUT.did"
        printf 'systemctl try-restart\n' >> "$RESTART_OUT"; exit 0 ;;
    is-active) [ -f "$RESTART_OUT.did" ] && [ "${FIXTURE_ACTIVE:-0}" = 0 ]; exit $? ;;
    is-failed) exit "${FIXTURE_FAILED:-1}" ;;
esac; done
exit 0
STUB
printf '#!/bin/sh\necho fixtureuser\n' > "$rbin/id"
printf '#!/bin/sh\necho 1000\n' > "$rbin/stat"
chmod +x "$rbin"/*
export RESTART_OUT="$work/restart.out"
mkdir -p "$rfix/1000/hypr/testsig"
python3 -c "
import socket
s = socket.socket(socket.AF_UNIX); s.bind('$rfix/1000/hypr/testsig/.socket.sock')
" 2>/dev/null || true

run_restarter() { # run_restarter <env assignments...>
    : > "$RESTART_OUT"; rm -f "$RESTART_OUT.did"
    env "$@" PATH="$rbin:$PATH" RESTART_OUT="$RESTART_OUT" bash "$rhelper" 2>&1
}

# It must bound every call it makes as another user: an unbounded
# systemctl against a socket the user controls holds pacman's lock for ever.
grep -qE 'timeout( -k [0-9]+)? [0-9]+ runuser' "$restarter" || {
    echo "the restarter must bound runuser: a user-owned socket can hang systemctl for ever" >&2
    exit 1; }

# An unlocked session is restarted, and the lock check carries a signature
# (without one the real hyprctl refuses, which reads as "not locked").
out=$(run_restarter FIXTURE_LOCKED=false || true)
grep -q 'systemctl try-restart' "$RESTART_OUT" || {
    echo "an unlocked session did not get its unit restarted" >&2; exit 1; }
grep -q 'HYPRLAND_INSTANCE_SIGNATURE=testsig' "$RESTART_OUT" || {
    echo "the lock check ran without a signature; the guard could never fire" >&2; exit 1; }
printf '%s' "$out" | grep -q 'restarted 1' || {
    echo "a real restart was not reported" >&2; exit 1; }

# A LOCKED session is left alone: hypridle is KillMode=control-group and a
# locker in its cgroup dies with it, which is a lockout, not an annoyance.
run_restarter FIXTURE_LOCKED=true >/dev/null || true
grep -q 'systemctl try-restart' "$RESTART_OUT" && {
    echo "a locked session was restarted; that can kill the locker" >&2; exit 1; }

# Unreadable lock state with a compositor present must FAIL CLOSED.
run_restarter FIXTURE_LOCKED=false FIXTURE_HYPRCTL_BROKEN=1 >/dev/null || true
grep -q 'systemctl try-restart' "$RESTART_OUT" && {
    echo "lock state was unreadable and it restarted anyway; that must fail closed" >&2
    exit 1; }

# A restart that dies immediately is NOT a success: the user is left with no
# idle policy at all, which is worse than the stale one they had.
out=$(run_restarter FIXTURE_LOCKED=false FIXTURE_ACTIVE=1 FIXTURE_FAILED=0 || true)
printf '%s' "$out" | grep -q 'failed state' || {
    echo "a unit that died on restart was not reported as failed" >&2; exit 1; }
printf '%s' "$out" | grep -q 'restarted 1' && {
    echo "a unit that died on restart was counted as a success" >&2; exit 1; }

# Ownership is enforced by behaviour, not by the string being present.
printf '#!/bin/sh\necho 4242\n' > "$rbin/stat"
run_restarter FIXTURE_LOCKED=false >/dev/null || true
[ -s "$RESTART_OUT" ] && {
    echo "ran as a user for a runtime dir that uid does not own" >&2; exit 1; }
printf '#!/bin/sh\necho 1000\n' > "$rbin/stat"

# Never fails the transaction, whatever happened. Tested with `if !`, since
# under set -e a bare invocation aborts before $? can be read.
if ! run_restarter FIXTURE_LOCKED=true >/dev/null 2>&1; then
    echo "the restarter must never fail the transaction" >&2; exit 1
fi

# Wired into both package managers, in its OWN pacman hook: alpm's Exec is
# not repeatable, so a second Exec in hook 95 silently replaces the reload
# that hook exists for.
grep -q 'hypr-de-restart-session-units' "$root/dist/pacman/96-hypr-de-restart-units.hook" || {
    echo "the restarter has no pacman hook of its own" >&2; exit 1; }
grep -q 'hypr-de-restart-session-units' "$root/packaging/hypr-de.spec" || {
    echo "the rpm scriptlet does not run the restarter" >&2; exit 1; }
for hook in "$root"/dist/pacman/*.hook; do
    # `|| true`: grep -c exits 1 on a zero count, which under set -e would
    # abort the suite at the assignment and never print why.
    n=$(grep -c '^Exec' "$hook" || true)
    [ "$n" = 1 ] || {
        echo "$(basename "$hook") has $n Exec lines; alpm keeps only the last" >&2; exit 1; }
done
grep -q 'hypr-de-reload-sessions' "$root/dist/pacman/95-hypr-de-reload.hook" || {
    echo "hook 95 no longer runs the config reload it exists for" >&2; exit 1; }
for hook in 95-hypr-de-reload 96-hypr-de-restart-units; do
    grep -q "$hook" "$root/packaging/PKGBUILD" || {
        echo "$hook is not installed by the PKGBUILD" >&2; exit 1; }
done

echo "lock policy routing is correct"
