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

if [ "$(id -u)" -ne 0 ]; then
    die "run as root (pipe into sudo sh). example:
  curl -fsSL https://raw.githubusercontent.com/MasonRhodesDev/hypr-DE/main/get-hypr-de.sh | sudo sh"
fi

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
    pacman -Syu --needed --noconfirm "${pkgs[@]}"
}

install_fedora() {
    say "Enabling COPRs"
    dnf install -y dnf-plugins-core
    local copr
    for copr in \
        solaris765/hypr-de \
        solaris765/hyprstate \
        solaris765/lmtt \
        solaris765/logind-idle-control \
        solaris765/hyprland-voice-dictation \
        solaris765/waybar-workspace-buttons \
        solaris765/vigil \
        solaris765/sni-watcher \
        solaris765/hyprstate-gui \
        solaris765/hypr-de-extras \
        nett00n/hyprland \
        heus-sueh/packages
    do
        dnf copr enable -y "$copr"
    done
    pkgs=(hypr-de)
    [ "$GAMING" = 1 ] && pkgs+=(hypr-de-gaming)
    say "Installing ${pkgs[*]}"
    dnf install -y "${pkgs[@]}"
}

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
