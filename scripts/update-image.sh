#!/bin/bash
# Bring a cloud image up to date and make it reusable.
#
# Usage: update-image.sh BASE.qcow2 OUT.qcow2 'UPDATE COMMAND' [REPORT_DIR]
#
# Boots BASE under qemu/KVM with a throwaway cloud-init seed, runs UPDATE
# COMMAND as root in the VM (for example `dnf -y upgrade
# --enablerepo=updates-testing`), cleans the guest so it boots like a fresh
# cloud image, powers it off and writes the result, flattened and
# compressed, to OUT. BASE is not modified.
#
# With REPORT_DIR it also writes
#   packages.txt   every package in the updated image
#   updated.txt    the packages the update added or changed
#
# Needs /dev/kvm, qemu-system-x86_64, qemu-img, ssh, and xorriso or
# genisoimage.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
[[ $# -ge 3 && $# -le 4 ]] || die "usage: $0 BASE.qcow2 OUT.qcow2 'UPDATE COMMAND' [REPORT_DIR]"
base="$(realpath "$1")" out="$2" update_cmd="$3" report="${4:-}"
[ -f "$base" ] || die "no such file: $base"
[ -w /dev/kvm ] || die "/dev/kvm is not writable: a KVM host is required"
for tool in qemu-system-x86_64 qemu-img ssh ssh-keygen python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
iso="$(command -v xorriso || command -v genisoimage || true)"
[ -n "$iso" ] || die "need xorriso or genisoimage"
[ -z "$report" ] || mkdir -p "$report"

work="$(mktemp -d "${TMPDIR:-/tmp}/update-image.XXXXXX")"
cleanup() {
    if [ -f "$work/qemu.pid" ]; then kill "$(cat "$work/qemu.pid")" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
ssh-keygen -q -t ed25519 -N '' -f "$work/key"
cat > "$work/user-data" <<EOF
#cloud-config
disable_root: false
ssh_pwauth: false
users:
  - default
  - name: root
    ssh_authorized_keys:
      - $(cat "$work/key.pub")
EOF
printf 'instance-id: update-%s\nlocal-hostname: image-update\n' "$RANDOM$RANDOM" > "$work/meta-data"
args=(-output "$work/seed.iso" -volid cidata -joliet -rock "$work/user-data" "$work/meta-data")
[ "$(basename "$iso")" != xorriso ] || args=(-as mkisofs "${args[@]}")
"$iso" "${args[@]}" >/dev/null 2>&1

# a copy-on-write overlay: BASE stays untouched; 20G leaves room for updates
qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$work/disk.qcow2" 20G
qemu-system-x86_64 -name image-update -machine q35,accel=kvm -cpu host \
    -smp 2 -m 4096 -display none -daemonize -pidfile "$work/qemu.pid" \
    -serial "file:$work/console.log" \
    -drive "file=$work/disk.qcow2,if=virtio,format=qcow2,discard=unmap" \
    -drive "file=$work/seed.iso,if=virtio,media=cdrom,readonly=on" \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$port-:22" \
    -device virtio-net-pci,netdev=n0

vm() {
    ssh -i "$work/key" -p "$port" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes \
        -o IdentitiesOnly=yes -o IdentityAgent=none \
        -o ConnectTimeout=5 root@127.0.0.1 "$@"
}

echo "== waiting for the VM"
for _ in $(seq 120); do vm true 2>/dev/null && break; sleep 3; done
vm true || { tail -n 30 "$work/console.log" >&2; die "the VM did not come up"; }
vm 'cloud-init status --wait >/dev/null 2>&1 || true'
vm 'grep PRETTY_NAME /etc/os-release'

pkgs="rpm -qa --qf '%{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort"
vm "$pkgs" > "$work/before.txt"

echo "== update: $update_cmd"
vm "$update_cmd"

vm "$pkgs" > "$work/after.txt"
# sorted here, in one locale: the guest's sort order is not ours
comm -13 <(LC_ALL=C sort "$work/before.txt") <(LC_ALL=C sort "$work/after.txt") > "$work/updated.txt"
echo "== $(wc -l < "$work/updated.txt") package(s) added or changed"
if [ -n "$report" ]; then
    cp "$work/after.txt" "$report/packages.txt"
    cp "$work/updated.txt" "$report/updated.txt"
fi

echo "== cleaning the guest"
# so that it boots like a fresh cloud image: cloud-init runs again, the host
# keys, machine id and hostname are made anew, our key is gone. The same
# command powers the VM off: once it has run, ssh no longer lets us in.
vm 'cloud-init clean --logs --seed
    rm -rf /root/.ssh /home/*/.ssh /etc/hostname
    rm -f /etc/ssh/ssh_host_* /var/lib/systemd/random-seed
    : > /etc/machine-id
    dnf clean all >/dev/null 2>&1; rm -rf /var/cache/dnf/* /var/tmp/* /tmp/*
    journalctl --rotate --vacuum-time=1s >/dev/null 2>&1 || true
    fstrim -av >/dev/null 2>&1 || true
    sync
    systemctl poweroff --no-block' 2>/dev/null || true   # our key is gone by now
for _ in $(seq 60); do kill -0 "$(cat "$work/qemu.pid")" 2>/dev/null || break; sleep 2; done
if kill -0 "$(cat "$work/qemu.pid")" 2>/dev/null; then die "the VM did not power off"; fi
rm -f "$work/qemu.pid"

echo "== writing $out"
qemu-img convert -O qcow2 -c "$work/disk.qcow2" "$out"
qemu-img info "$out" | grep -E 'virtual size|disk size'
