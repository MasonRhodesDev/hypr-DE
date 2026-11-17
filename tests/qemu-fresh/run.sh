#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

DISTRO=arch
cmd=start
for arg in "$@"; do
    case "$arg" in
        arch|fedora) DISTRO=$arg ;;
        reset|start|wait|reboot|check|test|upgrade|lock) cmd=$arg ;;
        -h|--help)
            sed -n '2,19p' "$0"
            exit 0
            ;;
        *)
            echo "unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

FEDORA_RELEASE="${HYPR_DE_FEDORA_RELEASE:-44}"
FEDORA_IMGDIR="https://download.fedoraproject.org/pub/fedora/linux/releases/$FEDORA_RELEASE/Cloud/x86_64/images"

if [ "$DISTRO" = fedora ]; then
    VMNAME=hypr-de-fresh-fedora
    WORKDIR="${HYPR_DE_QEMU_DIR:-$HOME/vms/hypr-de-fresh-fedora}"
    CLOUDIMG="$WORKDIR/Fedora-Cloud-Base-Generic-$FEDORA_RELEASE.qcow2"
    CLOUDIMG_URL="${HYPR_DE_CLOUDIMG_URL:-}"
    SSH_PORT="${HYPR_DE_SSH_PORT:-2223}"
else
    VMNAME=hypr-de-fresh
    WORKDIR="${HYPR_DE_QEMU_DIR:-$HOME/vms/hypr-de-fresh}"
    CLOUDIMG="$WORKDIR/Arch-Linux-x86_64-cloudimg.qcow2"
    CLOUDIMG_URL="${HYPR_DE_CLOUDIMG_URL:-https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2}"
    SSH_PORT="${HYPR_DE_SSH_PORT:-2222}"
fi
OVERLAY="$WORKDIR/overlay.qcow2"
CIDATA_DIR="$WORKDIR/cidata"
CIDATA_ISO="$WORKDIR/cidata.iso"
SSH_PUB="${HYPR_DE_SSH_PUB:-$HOME/.ssh/id_ed25519.pub}"
SSH_KEY="${HYPR_DE_SSH_KEY:-$HOME/.ssh/id_ed25519}"
PASSWORD="${HYPR_DE_PASSWORD:-hyprde}"
if [ "${HYPR_DE_HEADLESS:-0}" = 1 ]; then
    DISPLAY_MODE=none
else
    DISPLAY_MODE=gtk,show-cursor=on
fi

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need qemu-system-x86_64
need qemu-img
need xorriso
need openssl
need curl

stop_vm() {
    local pat="qemu-system-x86_64 -name $VMNAME -machine"
    if pgrep -f "$pat" >/dev/null; then
        echo "== stopping $VMNAME"
        pkill -f "$pat" || true
        for _ in $(seq 1 20); do
            pgrep -f "$pat" >/dev/null || break
            sleep 0.5
        done
    fi
}

ensure_cloudimg() {
    if [ -f "$CLOUDIMG" ]; then
        return 0
    fi
    if [ -z "$CLOUDIMG_URL" ]; then
        echo "== resolving Fedora cloudimg from $FEDORA_IMGDIR"
        local img
        img=$(curl -fsL "$FEDORA_IMGDIR/" \
            | grep -oE 'Fedora-Cloud-Base-Generic[^"]*\.x86_64\.qcow2' | head -1)
        [ -n "$img" ] || { echo "no Cloud-Base-Generic qcow2 in index" >&2; exit 1; }
        CLOUDIMG_URL="$FEDORA_IMGDIR/$img"
    fi
    echo "== downloading $DISTRO cloudimg"
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
instance-id: $VMNAME-$(date +%s)
local-hostname: $VMNAME
EOF
    cat >"$CIDATA_DIR/user-data" <<EOF
#cloud-config
hostname: $VMNAME
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
-name $VMNAME
-machine q35,accel=kvm
-cpu host
-m 6144
-smp 4
-drive if=virtio,file=$OVERLAY,discard=unmap,detect-zeroes=unmap
-drive if=virtio,file=$CIDATA_ISO,format=raw,media=cdrom,read-only=on
-netdev user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22
-device virtio-net-pci,netdev=net0
-vga virtio
-display $DISPLAY_MODE
-device virtio-tablet-pci
-usb
-device usb-kbd
-audio none
EOF
}

port_guard() {
    ss -ltn 2>/dev/null | grep -q ":$SSH_PORT " || return 0
    local holder
    holder=$(ss -ltnp 2>/dev/null | awk -v p=":$SSH_PORT " '$0 ~ p {match($0, /pid=[0-9]+/); print substr($0, RSTART+4, RLENGTH-4); exit}')
    if [ -n "$holder" ] && [ -f "$WORKDIR/qemu.pid" ] && [ "$holder" = "$(cat "$WORKDIR/qemu.pid")" ]; then
        return 0
    fi
    echo "ERROR: 127.0.0.1:$SSH_PORT is already held by pid ${holder:-unknown}" >&2
    ps -o pid,args= -p "${holder:-0}" 2>/dev/null | tail -1 >&2
    echo "Stop it first (that guest would be tested instead of a fresh one)." >&2
    exit 1
}

start_vm() {
    port_guard
    [ -f "$OVERLAY" ] || { echo "no overlay; run: $0 reset" >&2; exit 1; }
    [ -f "$CIDATA_ISO" ] || { echo "no cidata.iso; run: $0 reset" >&2; exit 1; }
    echo "== QEMU $VMNAME (SSH 127.0.0.1:$SSH_PORT, mason / $PASSWORD)"
    echo "   first-boot installer log: /var/log/get-hypr-de.log"
    if [ "${1:-}" = background ]; then
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
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=3 \
        -o BatchMode=yes \
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


enable_autologin() {
    echo "== enabling greetd autologin (test-only)"
    guest_ssh 'set -e
        sess=$(ls /usr/share/wayland-sessions/*uwsm*.desktop 2>/dev/null | head -1)
        [ -n "$sess" ] || sess=$(grep -l "Hyprland" /usr/share/wayland-sessions/*.desktop 2>/dev/null | head -1)
        [ -n "$sess" ] || { echo "no wayland session entry found" >&2; exit 1; }
        cmd=$(awk -F= "/^Exec=/{print \$2; exit}" "$sess")
        echo "   session entry: $sess"
        echo "   exec: $cmd"
        [ -f /etc/greetd/config.toml.bak ] || sudo cp /etc/greetd/config.toml /etc/greetd/config.toml.bak
        sudo cp /etc/greetd/config.toml.bak /etc/greetd/config.toml
        printf "\n[initial_session]\ncommand = \"%s\"\nuser = \"%s\"\n" "$cmd" "$USER" \
            | sudo tee -a /etc/greetd/config.toml >/dev/null
        sudo systemctl restart greetd
        sleep 2
        systemctl is-active greetd'
}

wait_session() {
    echo "== waiting for a live Hyprland session"
    local i
    for i in $(seq 1 60); do
        if guest_ssh 'pgrep -u mason -x Hyprland >/dev/null' 2>/dev/null; then
            echo "   session up ($i)"
            guest_ssh 'for _ in $(seq 1 30); do pgrep -u mason -x waybar >/dev/null && break; sleep 1; done' 2>/dev/null || true
            return 0
        fi
        sleep 2
    done
    echo "no Hyprland session appeared" >&2
    echo "--- greetd status ---" >&2
    guest_ssh 'systemctl is-active greetd; sudo systemctl status greetd --no-pager -l 2>&1 | tail -15' >&2 || true
    echo "--- greetd journal ---" >&2
    guest_ssh 'sudo journalctl -u greetd -b --no-pager | tail -20' >&2 || true
    exit 1
}

DOWNGRADED=0
downgrade_hypr_de() {
    if [ "$DISTRO" = fedora ]; then
        echo "== looking for a previous hypr-de in COPR"
        if guest_ssh 'sudo dnf -y downgrade hypr-de hypr-de-gaming >/dev/null 2>&1 || sudo dnf -y downgrade hypr-de >/dev/null 2>&1'; then
            DOWNGRADED=1
            echo "   downgraded to $(guest_ssh 'rpm -q --qf "%{VERSION}" hypr-de' 2>/dev/null)"
        else
            echo "   no older build available in COPR — running without a version change"
        fi
        return 0
    fi

    local prev="${HYPR_DE_PREV_TAG:-}"
    if [ -z "$prev" ]; then
        prev=$(curl -fsL https://api.github.com/repos/MasonRhodesDev/hypr-DE/releases \
            | grep -oE '"tag_name": *"v[0-9.]+"' | sed 's/.*"v/v/; s/"//' | sed -n 2p)
    fi
    if [ -z "$prev" ]; then
        echo "   could not resolve a previous release — running without a version change" >&2
        return 0
    fi
    echo "== downgrading hypr-de to $prev (previous release)"
    local base="https://github.com/MasonRhodesDev/hypr-DE/releases/download/$prev"
    local ver="${prev#v}"
    if guest_ssh "set -e
        cd /tmp
        curl -fsSLO '$base/hypr-de-$ver-1-any.pkg.tar.zst'
        curl -fsSLO '$base/hypr-de-gaming-$ver-1-any.pkg.tar.zst' || true
        sudo pacman -U --noconfirm hypr-de-$ver-1-any.pkg.tar.zst hypr-de-gaming-$ver-1-any.pkg.tar.zst 2>/dev/null \\
          || sudo pacman -U --noconfirm hypr-de-$ver-1-any.pkg.tar.zst
        pacman -Q hypr-de"
    then
        DOWNGRADED=1
    else
        echo "   downgrade failed — running without a version change" >&2
    fi
}

run_lock_test() {
    wait_ssh
    enable_autologin
    wait_session
    echo "== lock-survival check"
    guest_ssh 'bash -s' <"$HERE/lock-check.sh"
}

run_upgrade_test() {
    wait_ssh
    downgrade_hypr_de
    enable_autologin
    wait_session
    if [ "$DOWNGRADED" = 1 ]; then
        echo "== upgrading hypr-de under the live session (the real scenario)"
    else
        echo "== reinstalling hypr-de under the live session (no older build to come from)"
    fi
    local before after
    if [ "$DISTRO" = fedora ]; then
        before=$(guest_ssh 'rpm -q --qf "%{VERSION}" hypr-de' 2>/dev/null)
        guest_ssh 'set -e
            list=""
            for p in hypr-de hypr-de-gaming; do rpm -q "$p" >/dev/null 2>&1 && list="$list $p"; done
            echo "   upgrading:$list"
            sudo dnf -y upgrade $list 2>&1 | tail -4'
        after=$(guest_ssh 'rpm -q --qf "%{VERSION}" hypr-de' 2>/dev/null)
    else
        before=$(guest_ssh 'pacman -Q hypr-de | cut -d" " -f2' 2>/dev/null)
        guest_ssh 'sudo pacman -Syu --noconfirm 2>&1 | tail -5'
        after=$(guest_ssh 'pacman -Q hypr-de | cut -d" " -f2' 2>/dev/null)
    fi
    echo "   hypr-de: $before -> $after"
    if [ "$DOWNGRADED" = 1 ] && [ "$before" = "$after" ]; then
        echo "ERROR: downgraded to $before but the upgrade did not change the version" >&2
        exit 1
    fi
    echo "== upgrade checks"
    guest_ssh 'bash -s' <"$HERE/upgrade-check.sh"
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
    lock)
        stop_vm
        write_cidata
        reset_overlay
        start_vm background
        wait_firstboot
        run_lock_test
        ;;
    upgrade)
        stop_vm
        write_cidata
        reset_overlay
        start_vm background
        wait_firstboot
        run_upgrade_test
        ;;
esac
