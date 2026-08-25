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
[ "$(grep -cE '^[[:space:]]*ignore_inhibit=true$' "$conf")" = 1 ] || {
    echo "hypridle.conf: exactly one listener may ignore inhibitors" >&2; exit 1; }
block=$(awk '/^listener \{/{inb=1;b="";next} inb&&/^\}/{inb=0; if (b ~ /ignore_inhibit=true/) print b; next} inb{b=b $0 "\n"}' "$conf")
for want in 'timeout=30' 'condition_cmd=@LIBEXECDIR@/session-locked.sh' 'condition_retry=' \
            'on-timeout=@LIBEXECDIR@/dpms-off-if-locked.sh'; do
    printf '%s' "$block" | grep -q "^  $want" || {
        echo "hypridle.conf: the ignore_inhibit listener lost '$want'" >&2; exit 1; }
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
on-resume=hyprctl dispatch "hl.dsp.dpms({ action = '"'"'on'"'"' })"
on-timeout=@LIBEXECDIR@/dpms-off-if-locked.sh
on-timeout=@LIBEXECDIR@/lock-cmd.sh --idle'
got_cmds=$(sed -n 's/^[[:space:]]*\(on-timeout\|on-resume\|after_sleep_cmd\|before_sleep_cmd\|lock_cmd\)=/\1=/p' \
    "$conf" | sort)
[ "$got_cmds" = "$want_cmds" ] || {
    echo "hypridle.conf: the set of commands hypridle runs changed" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$want_cmds" "$got_cmds" >&2
    exit 1; }

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

echo "lock policy routing is correct"
