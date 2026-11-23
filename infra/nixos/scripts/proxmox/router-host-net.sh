#!/usr/bin/env bash
# Network changes on the Proxmox `router` node itself (not inside a VM). Run as root:
#
#   router-host-net.sh harden         # IPv6 off on the WAN bridge, no IPv6 RAs accepted
#   router-host-net.sh merge-bridges  # Wi-Fi port (enp4s0) and enp5s0 into the LAN bridge
#
# harden: the host has no business on the WAN. Today it holds an IPv6 link-local
#   address on vmbr0, where sshd, pveproxy and rpcbind listen on [::], reachable from
#   the ISP-side L2 (the Draytek). It also accepts router advertisements on every
#   bridge, so once OPNsense's radvd is gone any LAN device could hand it a rogue
#   prefix. Only the host's own IP stack changes; bridged traffic for the router VM
#   is untouched.
#
# merge-bridges: today the U6 Pro (enp4s0, vmbr2) reaches the wired LAN (enp3s0,
#   vmbr1) only through the router VM's bridge, so with no router VM running Wi-Fi
#   can't reach Proxmox, and all Wi-Fi<->server traffic crosses the router VM.
#   After this, vmbr1 holds all three LAN ports. vmbr2/vmbr3 stay as empty bridges,
#   because VM 100 (OPNSense) and VM 101 (gw) still have NICs on them (no loop:
#   nothing physical is on them anymore). Wi-Fi blips for about a second.
#   STP is off: never cable two of these ports to the same switch.
set -euo pipefail

log() { echo "[$(date +%T)] $*"; }

harden() {
  cat >/etc/sysctl.d/90-router-host.conf <<'EOF'
# Managed by kuberseni-gitops infra/nixos/scripts/proxmox/router-host-net.sh
# The host has no business on the WAN bridge.
net.ipv6.conf.enp2s0.disable_ipv6 = 1
net.ipv6.conf.vmbr0.disable_ipv6 = 1
# Don't take IPv6 router advertisements from anyone (no rogue-RA prefixes).
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.vmbr1.accept_ra = 0
net.ipv6.conf.vmbr2.accept_ra = 0
net.ipv6.conf.vmbr3.accept_ra = 0
EOF
  sysctl -q -p /etc/sysctl.d/90-router-host.conf
  log "IPv6 addresses left on the host:"
  ip -6 -br addr show | sed 's/^/  /'
}

merge_bridges() {
  local f=/etc/network/interfaces
  cp -a "$f" "$f.before-merge-$(date +%Y%m%d-%H%M%S)"

  log "runtime: enp4s0 and enp5s0 into vmbr1"
  for port in enp4s0 enp5s0; do
    ip link set "$port" nomaster
    ip link set "$port" master vmbr1
  done

  log "persist: $f"
  python3 - "$f" <<'EOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
def set_ports(text, bridge, ports):
    pat = re.compile(r"(iface %s inet [^\n]*\n(?:[ \t]+[^\n]*\n)*?[ \t]+bridge-ports )[^\n]*" % bridge)
    new, n = pat.subn(lambda m: m.group(1) + ports, text)
    if n != 1:
        sys.exit("couldn't find bridge-ports for %s" % bridge)
    return new
text = set_ports(text, "vmbr1", "enp3s0 enp4s0 enp5s0")
text = set_ports(text, "vmbr2", "none")
text = set_ports(text, "vmbr3", "none")
open(path, "w").write(text)
EOF
  log "vmbr1 ports now: $(ls /sys/class/net/vmbr1/brif | tr '\n' ' ')"
  grep -A3 -E '^iface vmbr[123]' "$f" | grep -E 'iface|bridge-ports' | sed 's/^/  /'
}

case ${1:-} in
  harden) harden ;;
  merge-bridges) merge_bridges ;;
  *)
    echo "usage: $0 harden|merge-bridges" >&2
    exit 1
    ;;
esac
