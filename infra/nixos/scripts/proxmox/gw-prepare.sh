#!/usr/bin/env bash
# Install gw as VM 101 on the Proxmox `router` node, stopped, ready for gw-cutover.sh.
# Changes nothing for the running network: the VM is never started here.
#
#   gw-prepare.sh <vzdump-qemu-gw.vma.zst> < age-key.txt
#
# stdin: gw's age private key (decrypt infra/nixos/hosts/gw/age-key.sops.json). It is
# written to /var/lib/sops-nix/key.txt on the VM's disk, so sops-nix can decrypt the
# PPPoE credentials on first boot.
set -euo pipefail
. "$(dirname "$0")/gw-lib.sh"

vma=${1:?usage: gw-prepare.sh <vma.zst> < age-key.txt}
key=$(cat)
grep -q '^AGE-SECRET-KEY-' <<<"$key" || { log "stdin is not an age key"; exit 1; }

if qm status $GW >/dev/null 2>&1; then
  log "VM $GW exists; replacing it (it must be stopped)"
  [ "$(qm status $GW | awk '{print $2}')" = stopped ] || { log "VM $GW is running: refusing"; exit 1; }
  qm destroy $GW --purge 0
fi

qmrestore "$vma" $GW --storage local-lvm --unique 0
# The image adds an unused cloud-init drive. onboot stays 0 until the cutover succeeds,
# so OPNSense and gw (same MACs, same IP) can never both start at boot.
qm set $GW --delete ide2 --onboot 0 --boot order=virtio0 --description "gw: NixOS router (infra/nixos in kuberseni-gitops)"

install_key() {
  install -d -m 700 "$ROOT/var/lib/sops-nix"
  (umask 077 && printf '%s\n' "$key" >"$ROOT/var/lib/sops-nix/key.txt")
}
with_gw_root install_key

log "VM $GW ready (stopped):"
qm config $GW | grep -E '^(name|memory|cores|net[0-9]|onboot|virtio0)'
