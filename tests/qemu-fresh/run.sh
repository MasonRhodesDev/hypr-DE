#!/bin/bash
# Fresh-Arch QEMU harness. First boot runs the **published** installer
# (same curl | sh a third party uses) and pacman packages from [mason].
# This checkout is never copied into the guest.
#
#   tests/qemu-fresh/run.sh reset   # new overlay + boot
#   tests/qemu-fresh/run.sh start   # boot existing overlay
#   tests/qemu-fresh/run.sh wait    # wait for SSH + firstboot ok
#   tests/qemu-fresh/run.sh reboot  # reboot guest, wait for SSH
#   tests/qemu-fresh/run.sh check   # second-boot file/unit/greeter checks
#   tests/qemu-fresh/run.sh test    # reset + wait + reboot + check
#
# Guest login: mason / hyprde (NOPASSWD sudo)
# SSH: ssh -p 2222 -i ~/.ssh/id_ed25519 mason@127.0.0.1
# Installer log in the guest: /var/log/get-hypr-de.log
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${HYPR_DE_QEMU_DIR:-$HOME/vms/hypr-de-fresh}"
CLOUDIMG="$WORKDIR/Arch-Linux-x86_64-cloudimg.qcow2"
CLOUDIMG_URL="${HYPR_DE_CLOUDIMG_URL:-https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2}"
OVERLAY="$WORKDIR/overlay.qcow2"
CIDATA_DIR="$WORKDIR/cidata"
CIDATA_ISO="$WORKDIR/cidata.iso"
SSH_PUB="${HYPR_DE_SSH_PUB:-$HOME/.ssh/id_ed25519.pub}"
SSH_KEY="${HYPR_DE_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PORT="${HYPR_DE_SSH_PORT:-2222}"
PASSWORD="${HYPR_DE_PASSWORD:-hyprde}"

cmd=start
for arg in "$@"; do
    case "$arg" in
        reset|start|wait|reboot|check|test) cmd=$arg ;;
        -h|--help)
            sed -n '2,16p' "$0"
            exit 0
            ;;
        *)
            echo "unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need qemu-system-x86_64
need qemu-img
need xorriso
need openssl
need curl

stop_vm() {
    if pgrep -f 'qemu-system-x86_64 -name hypr-de-fresh' >/dev/null; then
        echo "== stopping hypr-de-fresh"
        pkill -f 'qemu-system-x86_64 -name hypr-de-fresh' || true
        for _ in $(seq 1 20); do
            pgrep -f 'qemu-system-x86_64 -name hypr-de-fresh' >/dev/null || break
            sleep 0.5
        done
    fi
}

ensure_cloudimg() {
    if [ -f "$CLOUDIMG" ]; then
        return 0
    fi
    echo "== downloading Arch cloudimg"
    mkdir -p "$WORKDIR"
    curl -fL "$CLOUDIMG_URL" -o "$CLOUDIMG.partial"
    mv "$CLOUDIMG.partial" "$CLOUDIMG"
}

write_cidata() {
    [ -f "$SSH_PUB" ] || { echo "no SSH pubkey at $SSH_PUB" >&2; exit 1; }
    local pubkey hash firstboot_b64
    pubkey=$(tr -d '\n' <"$SSH_PUB")
    hash=$(openssl passwd -6 "$PASSWORD")
    firstboot_b64=$(base64 -w0 "$HERE/firstboot.sh")

    mkdir -p "$CIDATA_DIR"
    cat >"$CIDATA_DIR/meta-data" <<EOF
instance-id: hypr-de-fresh-$(date +%s)
local-hostname: hypr-de-fresh
EOF
    cat >"$CIDATA_DIR/user-data" <<EOF
#cloud-config
hostname: hypr-de-fresh
users:
  - name: mason
    gecos: Mason
    groups: [wheel]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: '$hash'
    ssh_authorized_keys:
      - $pubkey
ssh_pwauth: true
chpasswd:
  expire: false
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
package_update: false
write_files:
  - path: /usr/local/sbin/hypr-de-firstboot.sh
    permissions: '0755'
    encoding: b64
    content: $firstboot_b64
  - path: /etc/systemd/system/hypr-de-firstboot.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Install hypr-DE on first boot
      Wants=network-online.target
      After=network-online.target systemd-user-sessions.service
      ConditionPathExists=!/var/lib/hypr-de-firstboot.done

      [Service]
      Type=oneshot
      TimeoutStartSec=1h
      StandardOutput=journal+console
      StandardError=journal+console
      ExecStart=/usr/local/sbin/hypr-de-firstboot.sh
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
runcmd:
  - [systemctl, enable, --now, hypr-de-firstboot.service]
EOF
    (
        cd "$CIDATA_DIR"
        xorriso -as mkisofs -quiet -V CIDATA -o "$CIDATA_ISO" -r -J user-data meta-data
    )
}

reset_overlay() {
    ensure_cloudimg
    echo "== new overlay from cloudimg"
    rm -f "$OVERLAY"
    qemu-img create -f qcow2 -F qcow2 -b "$CLOUDIMG" "$OVERLAY"
    qemu-img resize "$OVERLAY" 40G
    rm -f "$WORKDIR/known_hosts"
}

qemu_args() {
    cat <<EOF
-name hypr-de-fresh
-machine q35,accel=kvm
-cpu host
-m 6144
-smp 4
-drive if=virtio,file=$OVERLAY,discard=unmap,detect-zeroes=unmap
-drive if=virtio,file=$CIDATA_ISO,format=raw,media=cdrom,read-only=on
-netdev user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22
-device virtio-net-pci,netdev=net0
-vga virtio
-display gtk,show-cursor=on
-device virtio-tablet-pci
-usb
-device usb-kbd
-audio none
EOF
}

start_vm() {
    [ -f "$OVERLAY" ] || { echo "no overlay; run: $0 reset" >&2; exit 1; }
    [ -f "$CIDATA_ISO" ] || { echo "no cidata.iso; run: $0 reset" >&2; exit 1; }
    echo "== QEMU hypr-de-fresh (SSH 127.0.0.1:$SSH_PORT, mason / $PASSWORD)"
    echo "   first-boot installer log: /var/log/get-hypr-de.log"
    if [ "${1:-}" = background ]; then
        # Intentional word splitting of qemu_args.
        # shellcheck disable=SC2046
        qemu-system-x86_64 $(qemu_args) &
        echo $! >"$WORKDIR/qemu.pid"
        return 0
    fi
    # shellcheck disable=SC2046
    exec qemu-system-x86_64 $(qemu_args)
}

guest_ssh() {
    ssh -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$WORKDIR/known_hosts" \
        -o ConnectTimeout=5 \
        -p "$SSH_PORT" -i "$SSH_KEY" \
        mason@127.0.0.1 "$@"
}

wait_ssh() {
    echo "== waiting for SSH"
    local i
    for i in $(seq 1 60); do
        if guest_ssh true 2>/dev/null; then
            echo "   ssh up ($i)"
            return 0
        fi
        sleep 3
    done
    echo "SSH never came up" >&2
    exit 1
}

wait_firstboot() {
    wait_ssh
    echo "== waiting for firstboot installer"
    local i st
    for i in $(seq 1 180); do
        st=$(guest_ssh 'cat /var/lib/hypr-de-firstboot.status 2>/dev/null || echo none' 2>/dev/null || echo none)
        case "$st" in
            ok)
                echo "   firstboot ok ($i)"
                return 0
                ;;
            fail)
                echo "firstboot failed; last log:" >&2
                guest_ssh 'sudo tail -40 /var/log/get-hypr-de.log' >&2 || true
                exit 1
                ;;
        esac
        sleep 5
    done
    echo "firstboot timed out (status=$st)" >&2
    guest_ssh 'sudo tail -40 /var/log/get-hypr-de.log' >&2 || true
    exit 1
}

reboot_guest() {
    wait_ssh
    echo "== rebooting guest"
    guest_ssh 'sudo systemctl reboot' || true
    local i
    for i in $(seq 1 30); do
        guest_ssh true 2>/dev/null || break
        sleep 1
    done
    wait_ssh
}

run_check() {
    wait_ssh
    echo "== second-boot check"
    guest_ssh 'bash -s' <"$HERE/check.sh"
}

case "$cmd" in
    reset)
        stop_vm
        write_cidata
        reset_overlay
        start_vm
        ;;
    start)
        start_vm
        ;;
    wait)
        wait_firstboot
        ;;
    reboot)
        reboot_guest
        ;;
    check)
        run_check
        ;;
    test)
        stop_vm
        write_cidata
        reset_overlay
        start_vm background
        wait_firstboot
        reboot_guest
        run_check
        ;;
esac
