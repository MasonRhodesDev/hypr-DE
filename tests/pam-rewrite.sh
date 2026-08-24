#!/bin/bash
# hypr-de-sys-setup edits /etc/pam.d/greetd as root from the package
# scriptlet. See issue #15: it used to pipe awk over the live file with no
# validation and no backup, so a bad rewrite meant a login lockout. These
# cases pin the rule -- when anything looks wrong, the original survives.
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

HYPR_DE_SYS_SETUP_LIB=1
export HYPR_DE_SYS_SETUP_LIB
# shellcheck source=/dev/null
. "$root/dist/libexec/hypr-de-sys-setup"
unset HYPR_DE_SYS_SETUP_LIB
set +e

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

arch_pam() {
    cat > "$1" <<'PAM'
#%PAM-1.0
auth       include      system-local-login
account    include      system-local-login
password   include      system-local-login
session    include      system-local-login
PAM
}

echo "== the normal case still wires the keyring"
pam="$work/greetd"; arch_pam "$pam"
before=$(cat "$pam")
out=$(wire_keyring_pam "$pam" 2>&1)
n=$(grep -c pam_gnome_keyring.so "$pam")
[ "$n" -eq 3 ] && ok "inserted 3 keyring lines" || bad "inserted $n keyring lines"
missing=0
while IFS= read -r l; do grep -qxF -- "$l" "$pam" || missing=1; done <<< "$before"
[ "$missing" -eq 0 ] && ok "every original line survived" || bad "the rewrite dropped an original line"
ls "$pam".hypr-de-backup.* >/dev/null 2>&1 && ok "backup written" || bad "no backup written"
printf '%s' "$out" | grep -q "backup:" && ok "reported the backup path" || bad "did not report the backup"

echo
echo "== running it twice changes nothing"
sum=$(md5sum < "$pam")
wire_keyring_pam "$pam" >/dev/null 2>&1
[ "$(md5sum < "$pam")" = "$sum" ] && ok "idempotent" || bad "second run modified the file"
[ "$(ls "$pam".hypr-de-backup.* | wc -l)" -eq 1 ] && ok "no second backup" || bad "backed up again on a no-op"

echo
echo "== a rewrite that comes out empty must not touch the original"
# Exactly the reported failure: an awk that produces nothing (a different
# awk, or a PAM file this was not written against).
pam="$work/greetd-empty"; arch_pam "$pam"
before=$(cat "$pam")
stub="$work/stub"; mkdir -p "$stub"
printf '#!/bin/sh\nexit 0\n' > "$stub/awk"; chmod +x "$stub/awk"
out=$(PATH="$stub:$PATH" wire_keyring_pam "$pam" 2>&1)
[ "$(cat "$pam")" = "$before" ] && ok "original intact after an empty rewrite" || bad "TRUNCATED the live PAM file"
printf '%s' "$out" | grep -q "came out empty" && ok "said why it refused" || bad "no explanation: $out"
ls "$pam".hypr-de-backup.* >/dev/null 2>&1 && bad "backed up despite refusing" || ok "no pointless backup"

echo
echo "== a rewrite that loses lines must not touch the original"
pam="$work/greetd-lossy"; arch_pam "$pam"
before=$(cat "$pam")
printf '#!/bin/sh\necho "-auth optional pam_gnome_keyring.so"\n' > "$stub/awk"
out=$(PATH="$stub:$PATH" wire_keyring_pam "$pam" 2>&1)
[ "$(cat "$pam")" = "$before" ] && ok "original intact after a lossy rewrite" || bad "REPLACED the PAM file with a partial one"
printf '%s' "$out" | grep -q "dropped a line" && ok "said why it refused" || bad "no explanation: $out"

echo
echo "== a failing awk must not touch the original"
pam="$work/greetd-awkfail"; arch_pam "$pam"
before=$(cat "$pam")
printf '#!/bin/sh\necho boom >&2\nexit 2\n' > "$stub/awk"
out=$(PATH="$stub:$PATH" wire_keyring_pam "$pam" 2>&1)
[ "$(cat "$pam")" = "$before" ] && ok "original intact after awk failed" || bad "modified the file after awk failed"
printf '%s' "$out" | grep -q "awk failed" && ok "said why it refused" || bad "no explanation: $out"

echo
echo "== a PAM file with no insertion point is left alone, with a reason"
pam="$work/greetd-fedora"
cat > "$pam" <<'PAM'
#%PAM-1.0
auth       substack     password-auth
account    include      password-auth
session    include      password-auth
PAM
before=$(cat "$pam")
out=$(wire_keyring_pam "$pam" 2>&1)
[ "$(cat "$pam")" = "$before" ] && ok "unchanged" || bad "rewrote a file it found no insertion point in"
printf '%s' "$out" | grep -q "no insertion point" && ok "said so" || bad "silently did nothing: $out"
ls "$pam".hypr-de-backup.* >/dev/null 2>&1 && bad "backed up a file it did not change" || ok "no backup"

echo
echo "== file identity is preserved"
pam="$work/greetd-mode"; arch_pam "$pam"; chmod 0644 "$pam"
ino_before=$(stat -c %i "$pam"); mode_before=$(stat -c %a "$pam")
wire_keyring_pam "$pam" >/dev/null 2>&1
[ "$(stat -c %i "$pam")" = "$ino_before" ] && ok "same inode (mode/owner/label kept)" || bad "replaced the inode"
[ "$(stat -c %a "$pam")" = "$mode_before" ] && ok "mode unchanged ($mode_before)" || bad "mode changed"

echo
echo "== a missing PAM file is not an error"
wire_keyring_pam "$work/does-not-exist" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "returns 0" || bad "failed on a missing file (would fail the transaction)"

echo
[ "$fail" -eq 0 ] && { echo "PAM rewrite is safe"; exit 0; }
exit 1
