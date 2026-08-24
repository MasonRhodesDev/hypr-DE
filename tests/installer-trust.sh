#!/bin/bash
# get-hypr-de.sh trust behaviour: what the installer retries, what it refuses,
# and that no COPR is enabled on an unpinned key. See issue #11.
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

HYPR_DE_INSTALLER_LIB=1
export HYPR_DE_INSTALLER_LIB
# shellcheck source=/dev/null
. "$root/get-hypr-de.sh"
unset HYPR_DE_INSTALLER_LIB

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

# A stand-in package manager: records each attempt, prints canned output.
attempts="$work/attempts"
emit() {  # emit <status> <output>
    echo x >> "$attempts"
    printf '%s\n' "$2"
    return "$1"
}

# Drive the real retry_pkg so precedence between the two classifiers is
# exercised rather than re-implemented here.
check_retry() {  # check_retry <label> <expected attempts> <status> <output>
    local label="$1" want="$2" status="$3" out="$4" rc=0 n
    : > "$attempts"
    ( HYPR_DE_RETRIES=3 HYPR_DE_RETRY_DELAY=0 \
        retry_pkg "install" emit "$status" "$out" ) >/dev/null 2>&1 || rc=$?
    n=$(wc -l < "$attempts")
    if [ "$n" -eq "$want" ]; then
        ok "$label: $n attempt(s)"
    else
        bad "$label: expected $want attempt(s), got $n"
    fi
    printf '%s' "$rc" > "$work/rc"
}

echo "== signature failures are refused, never retried"
check_retry "pacman: signature is invalid" 1 1 \
    'error: mason: signature from "Mason Rhodes" is invalid
error: failed to synchronize all databases (invalid or corrupted database (PGP signature))'
check_retry "pacman: corrupt db (PGP signature) alone" 1 1 \
    'error: failed to synchronize all databases (invalid or corrupted database (PGP signature))'
check_retry "dnf: repomd.xml GPG" 1 1 \
    'Error: Failed to download metadata: repomd.xml GPG signature verification error'
check_retry "dnf: GPG check FAILED" 1 1 \
    'Error: GPG check FAILED for package hypr-de-0.2.23-1.fc42.x86_64'
check_retry "pacman: could not be verified" 1 1 \
    'error: hypr-de: key "..." could not be verified'
[ "$(cat "$work/rc")" != 0 ] && ok "refusal exits non-zero" || bad "refusal exited 0"

echo "== genuinely transient failures still retry"
check_retry "corrupt db, no signature involved" 3 1 \
    'error: failed to synchronize all databases (invalid or corrupted database)'
check_retry "http 503" 3 1 'Errors during downloading metadata: Status code: 503'
check_retry "connection reset" 3 1 'curl: (56) Connection reset by peer'

echo "== everything else fails on the first attempt"
check_retry "package not found" 1 1 'error: target not found: hypr-de'
check_retry "success" 1 0 'resolving dependencies...'
[ "$(cat "$work/rc")" = 0 ] && ok "success exits 0" || bad "success exited non-zero"

echo "== every COPR is pinned"
n=${#COPR_KEYS[@]}
[ "$n" -eq 11 ] && ok "$n COPRs pinned" || bad "expected 11 pinned COPRs, got $n"
seen=""
for entry in "${COPR_KEYS[@]}"; do
    copr=${entry%% *}
    fpr=${entry##* }
    case "$copr" in */*) ;; *) bad "malformed COPR name: $copr" ;; esac
    if printf '%s' "$fpr" | grep -qE '^[0-9A-F]{40}$'; then
        ok "$copr pinned to $fpr"
    else
        bad "$copr has no usable fingerprint: $fpr"
    fi
    case " $seen " in *" $fpr "*) bad "$copr reuses a pinned fingerprint" ;; esac
    seen="$seen $fpr"
done

echo "== a key that is not the pinned one is refused"
if command -v gpg >/dev/null 2>&1; then
    fixture="$root/tests/fixtures/installer/copr-solaris765-hypr-de.pubkey.asc"
    PATH="$root/tests/fixtures/installer/bin:$PATH"   # stub install(1)/rpm(1)
    fetch() { cp "$fixture" "$2"; }                   # no network in a test
    real_fpr=35DAF337625EC32DFEDFEAB5F984020F51D7DA3D

    rc=0; ( copr_pin_key solaris765/hypr-de "$real_fpr" ) >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && ok "the pinned key is accepted" || bad "the pinned key was rejected (rc=$rc)"

    rc=0
    msg=$( ( copr_pin_key solaris765/hypr-de 0000000000000000000000000000000000000000 ) 2>&1 ) || rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$msg" | grep -q "not signed by the key this installer pins"; then
        ok "a swapped key is refused before the COPR is enabled"
    else
        bad "a swapped key was NOT refused (rc=$rc)"
    fi
else
    echo "skip  no gpg in this environment"
fi

echo
[ "$fail" -eq 0 ] && { echo "installer trust behaviour is correct"; exit 0; }
exit 1
