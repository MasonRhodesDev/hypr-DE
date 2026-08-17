#!/bin/bash
# Runs once on the QEMU guest (cloud-init). Not invoked on the host.
set -euo pipefail
mkdir -p /var/log /var/lib
exec >>/var/log/get-hypr-de.log 2>&1
echo "=== hypr-de firstboot $(date -Is) ==="
echo running >/var/lib/hypr-de-firstboot.status
trap 'echo fail >/var/lib/hypr-de-firstboot.status' ERR

# Arch guest only; Fedora's dnf parallelizes by default.
[ -f /etc/pacman.conf ] && sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf

ok_net=0
for _ in $(seq 1 60); do
    if curl -fsS --connect-timeout 2 https://geo.mirror.pkgbuild.com >/dev/null 2>&1 \
        || curl -fsS --connect-timeout 2 https://github.com >/dev/null 2>&1; then
        ok_net=1
        break
    fi
    sleep 2
done
[ "$ok_net" = 1 ] || {
    echo "network never came up"
    exit 1
}

user=mason
uid=$(id -u "$user")
loginctl enable-linger "$user" || true
systemctl start "user@$uid.service" || true
export SUDO_USER="$user"

# Published installer only — same command as the README. Packages come
# from [mason] / COPR, never from a host checkout.
curl -fsSL https://raw.githubusercontent.com/MasonRhodesDev/hypr-DE/main/get-hypr-de.sh | sh

touch /var/lib/hypr-de-firstboot.done
echo ok >/var/lib/hypr-de-firstboot.status
echo "=== hypr-de firstboot done $(date -Is) ==="
