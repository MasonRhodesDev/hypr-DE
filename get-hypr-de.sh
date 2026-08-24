#!/bin/bash
# Add the hypr-DE package repo and install hypr-de.
#
#   curl -fsSL https://raw.githubusercontent.com/MasonRhodesDev/hypr-DE/main/get-hypr-de.sh | sudo sh
#   wget -qO- https://raw.githubusercontent.com/MasonRhodesDev/hypr-DE/main/get-hypr-de.sh | sudo sh
#
# Options (after the pipe, via `sudo sh -s --`):
#   --gaming    also install hypr-de-gaming
#   --no-setup  skip per-user hypr-de-setup
set -euo pipefail

KEY_URL="https://masonrhodesdev.github.io/arch-repo/mason-repo.asc"
KEY_FPR="41450EEF8CEE7AB8CD3896221284404A6B70485C"
REPO_URL="https://masonrhodesdev.github.io/arch-repo/x86_64"

GAMING=0
SETUP=1
for arg in "$@"; do
    case "$arg" in
        --gaming) GAMING=1 ;;
        --no-setup) SETUP=0 ;;
        -h|--help)
            echo "usage: get-hypr-de.sh [--gaming] [--no-setup]"
            exit 0
            ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

say() { printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

fetch() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        die "need curl or wget"
    fi
}


# Repo metadata can be served mid-republish: GitHub Pages (and any CDN in
# front of a COPR mirror) will happily hand out a database from one publish
# and its index from another, and the install dies with
#   error: failed to synchronize all databases (invalid or corrupted database)
# It is transient and clears within a minute, but a one-shot installer just
# fails in the user's face. Retry those specific errors after dropping the
# cached metadata; anything else fails immediately as before.
TRANSIENT_RE='invalid or corrupted (database|package)|Status code: 5[0-9][0-9]|Connection (timed out|reset)'

# Signature failures are deliberately NOT transient, and this list is checked
# first so the "(PGP signature)" flavour of a corrupt-database error cannot
# fall through to the retry set above. pacman and dnf refuse the artifact
# either way, so a retry was never a bypass -- but calling a failed signature
# "transient repo metadata" four times over trains the user to read a real
# attack, or a hijacked mirror, as a CDN glitch. It fails once, loudly.
UNTRUSTED_RE='signature from .* is invalid|signature .* is unknown trust|could not be verified|repomd\.xml.*(signature|GPG)|GPG check FAILED|invalid or corrupted (database|package) \(PGP signature\)'

retry_pkg() {  # retry_pkg <label> <cmd...>
    local label="$1"; shift
    local tries="${HYPR_DE_RETRIES:-4}" delay="${HYPR_DE_RETRY_DELAY:-15}" i out rc
    for i in $(seq 1 "$tries"); do
        # `if cmd` is exempt from errexit, so this captures the status without
        # toggling set -e (which would leak out of this function).
        if out=$("$@" 2>&1); then rc=0; else rc=$?; fi
        printf '%s\n' "$out"
        [ "$rc" -eq 0 ] && return 0
        if printf '%s' "$out" | grep -qiE "$UNTRUSTED_RE"; then
            die "$label: signature verification FAILED -- not retrying.

The repository metadata or a package did not verify against the pinned
signing key, so nothing was installed.

This can be a repo caught mid-publish, which clears on its own. From here it
is indistinguishable from a tampered package or a hijacked mirror, so the
installer will not retry past it. Re-run once; if it fails the same way
again, stop and find out why before installing anything."
        fi
        if ! printf '%s' "$out" | grep -qiE "$TRANSIENT_RE"; then
            return "$rc"   # a real failure: do not paper over it
        fi
        if [ "$i" -eq "$tries" ]; then
            die "$label failed after $tries attempts (repo metadata still inconsistent)"
        fi
        say "$label hit transient repo metadata; refreshing and retrying ($i/$((tries - 1)))"
        if command -v pacman >/dev/null 2>&1; then
            rm -f /var/lib/pacman/sync/mason.db /var/lib/pacman/sync/mason.db.sig 2>/dev/null || true
        else
            dnf clean metadata >/dev/null 2>&1 || true
        fi
        sleep "$delay"
    done
}

install_arch() {
    say "Installing [mason] repo key"
    pacman -S --needed --noconfirm gnupg curl >/dev/null
    # pubring can exist without a secret key; lsign still needs --init.
    pacman-key --init
    key=$(mktemp)
    fetch "$KEY_URL" "$key"
    got=$(gpg --show-keys --with-colons "$key" | awk -F: '$1 == "fpr" { print $10; exit }')
    [ "$got" = "$KEY_FPR" ] || die "mason repo key fingerprint mismatch (got $got)"
    pacman-key --add "$key"
    pacman-key --lsign-key "$KEY_FPR"
    rm -f "$key"

    if ! grep -q '^\[mason\]' /etc/pacman.conf; then
        say "Adding [mason] to /etc/pacman.conf"
        cat >> /etc/pacman.conf <<EOF

[mason]
SigLevel = Required DatabaseRequired
Server = $REPO_URL
EOF
    else
        say "[mason] already in pacman.conf"
    fi

    pkgs=(hypr-de)
    [ "$GAMING" = 1 ] && pkgs+=(hypr-de-gaming)
    say "Installing ${pkgs[*]}"
    # -Syy on retry: the cached db is exactly what may be inconsistent.
    retry_pkg "install" pacman -Syyu --needed --noconfirm "${pkgs[@]}"
}

# Pinned COPR signing keys. `dnf copr enable -y` accepts whatever key the
# repository serves at enable time, so the one-liner would hand permanent
# root package trust to eleven publishers -- two of them unrelated third
# parties -- on nothing but "the URL looked right". The Arch path has always
# pinned its key (KEY_FPR); this is the Fedora half of that.
#
# Re-pin after a legitimate key rotation, verifying the new fingerprint out
# of band first:
#   curl -fsSL https://download.copr.fedorainfracloud.org/results/<owner>/<project>/pubkey.gpg \
#     | gpg --show-keys --with-colons | awk -F: '$1 == "fpr" { print $10; exit }'
COPR_KEYS=(
    "solaris765/hypr-de                  35DAF337625EC32DFEDFEAB5F984020F51D7DA3D"
    "solaris765/hyprstate                F165E7735518C392EB7EEAF0C4A6E35AB4EBE64F"
    "solaris765/lmtt                     371B84F2D121167A94578347347264EF782F61D0"
    "solaris765/logind-idle-control      A6C1D94563778B48D9FB1683330F53FFB7988770"
    "solaris765/waybar-workspace-buttons CC4E2FCEA4DC75954DDE76B983005FC443A84721"
    "solaris765/vigil                    D9A3EB9EDBEB027D28F4229810A4AED65CEE37A2"
    "solaris765/sni-watcher              784281BDCD1C6659B142CA8A501DB33B985A08B5"
    "solaris765/dials                    961FF0E44F214971CEB5D7015C0DD57055459320"
    "solaris765/hypr-de-extras           06C782624F7339B1F1DBE8AC485FEDD2D7DD0680"
    "nett00n/hyprland                    CE4F9876716F2756FE6A576AA5B5F0CF64407CDC"
    "heus-sueh/packages                  3FF21D0C4A29C4145780C98A1EE41438D0EFE2B9"
)

# Fetch a COPR's signing key, refuse it unless it is the pinned one, and
# install it locally. Prints the path to the verified key.
copr_pin_key() {  # copr_pin_key <owner/project> <fingerprint>
    local copr="$1" want="$2"
    local owner="${copr%%/*}" project="${copr##*/}"
    local tmp got dest
    tmp=$(mktemp)
    fetch "https://download.copr.fedorainfracloud.org/results/$owner/$project/pubkey.gpg" "$tmp" \
        || die "could not fetch the signing key for COPR $copr"
    got=$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
    if [ "$got" != "$want" ]; then
        rm -f "$tmp"
        die "COPR $copr is not signed by the key this installer pins.
  expected: $want
  got:      ${got:-<no key>}
Not enabling it. Enabling would grant root package trust to whoever holds
that key, for every update from now on. If the project rotated its key,
verify the new fingerprint out of band and update COPR_KEYS."
    fi
    dest="/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-$owner-$project"
    install -Dm644 "$tmp" "$dest"
    rm -f "$tmp"
    rpm --import "$dest" >&2
    printf '%s\n' "$dest"
}

install_fedora() {
    say "Enabling COPRs (pinned keys)"
    dnf install -y dnf-plugins-core gnupg2
    local entry copr want owner project keyfile repofile
    for entry in "${COPR_KEYS[@]}"; do
        copr=${entry% *}
        want=${entry##* }
        owner=${copr%%/*}
        project=${copr##*/}
        keyfile=$(copr_pin_key "$copr" "$want")
        dnf copr enable -y "$copr"
        # Point the generated .repo at the copy we just verified. Left as the
        # upstream URL, a later key swap would be re-fetched and auto-imported
        # by -y on the next update, which is the whole thing being prevented.
        repofile=$(grep -ls "results/$owner/$project" /etc/yum.repos.d/*.repo 2>/dev/null | head -1)
        if [ -n "$repofile" ]; then
            sed -i "s|^gpgkey=.*|gpgkey=file://$keyfile|" "$repofile"
        else
            printf '!! could not find the .repo file for %s; its key stays network-fetched\n' "$copr" >&2
        fi
    done
    pkgs=(hypr-de)
    [ "$GAMING" = 1 ] && pkgs+=(hypr-de-gaming)
    say "Installing ${pkgs[*]}"
    retry_pkg "install" dnf install -y --refresh "${pkgs[@]}"
}

# Sourced by tests/installer-trust.sh to exercise the classifiers and the key
# pinning without running an install.
if [ -n "${HYPR_DE_INSTALLER_LIB:-}" ]; then
    return 0 2>/dev/null || exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    die "run as root (pipe into sudo sh). example:
  curl -fsSL https://raw.githubusercontent.com/MasonRhodesDev/hypr-DE/main/get-hypr-de.sh | sudo sh"
fi

. /etc/os-release
# shellcheck disable=SC2153
case "$ID" in
    arch|cachyos|endeavouros) DISTRO=arch ;;
    fedora) DISTRO=fedora ;;
    *)
        case "${ID_LIKE:-}" in
            *arch*) DISTRO=arch ;;
            *fedora*) DISTRO=fedora ;;
            *) die "unsupported distro: $ID (arch/fedora only)" ;;
        esac
        ;;
esac

say "hypr-DE is alpha. Expect breakage."

if [ "$DISTRO" = arch ]; then
    install_arch
else
    install_fedora
fi

if [ "$SETUP" = 1 ]; then
    user="${SUDO_USER:-}"
    if [ -n "$user" ] && [ "$user" != root ] && command -v hypr-de-setup >/dev/null 2>&1; then
        say "Running hypr-de-setup as $user"
        uid=$(id -u "$user")
        runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" hypr-de-setup \
            || printf '!! hypr-de-setup failed; run it later as %s\n' "$user"
    else
        printf '\n== per user, run: hypr-de-setup\n'
    fi
fi

cat <<'EOF'

Done. Reboot, then pick Hyprland (uwsm-managed) at the vigil greeter.
EOF
