#!/usr/bin/env python3
"""Check that gw's DHCP reservations match OPNSense's in OpenTofu.

Until gw replaces OPNSense, infra/terraform is the source of truth for the LAN's
reservations. This reads them from the .tf files and compares them with
hosts/gw/dhcp-reservations.json. With --write, it rewrites the JSON instead.

Reads:
  - literal opnsense_kea_dhcpv4_reservation blocks in opnsense.tf
  - the VM inventory locals in vms.tf (one VM per line, with ip and mac)
  - the TrueNAS reservation, whose MAC lives in truenas-scale.tf
"""

import json
import re
import sys
from pathlib import Path

NIXOS = Path(__file__).resolve().parent.parent
TF = NIXOS.parent / "terraform"
JSON_PATH = NIXOS / "hosts" / "gw" / "dhcp-reservations.json"


def tofu_locals():
    """Map local name -> {ip, mac} from `name = { ... ip = "..." ... mac = "..." }` entries."""
    out = {}
    for tf in TF.glob("*.tf"):
        text = tf.read_text()
        for m in re.finditer(r'^\s*([\w-]+)\s*=\s*\{(.*?)\}', text, re.M | re.S):
            body = m.group(2)
            ip = re.search(r'\bip\s*=\s*"([\d.]+)"', body)
            mac = re.search(r'\bmac\s*=\s*"([0-9A-Fa-f:]+)"', body)
            if ip and mac:
                out[m.group(1)] = {"ip": ip.group(1), "mac": mac.group(1)}
    return out


def from_tofu():
    found = []
    locals_ = tofu_locals()

    def add(hostname, mac, ip):
        found.append({"hostname": hostname, "mac": mac.lower(), "ip": ip})

    # The for_each reservations (control plane, workers) come from the VM inventory.
    for line in (TF / "vms.tf").read_text().splitlines():
        m = re.match(r'\s*([\w-]+)\s*=\s*\{.*\bip\s*=\s*"([\d.]+)".*\bmac\s*=\s*"([0-9A-Fa-f:]+)"', line)
        if m:
            add(m.group(1), m.group(3), m.group(2))

    truenas_mac = re.search(r'mac_address\s*=\s*"([0-9A-Fa-f:]+)"', (TF / "truenas-scale.tf").read_text()).group(1)

    def value(block, attr, kind):
        lit = re.search(r'%s\s*=\s*"([^"]+)"' % attr, block)
        if lit:
            return lit.group(1)
        ref = re.search(r'%s\s*=\s*(?:lower\()?local\.([\w-]+)\.%s' % (attr, kind), block)
        if ref and ref.group(1) in locals_:
            return locals_[ref.group(1)][kind]
        return None

    for tf in sorted(TF.glob("*.tf")):
        for block in re.findall(r'resource "opnsense_kea_dhcpv4_reservation" "\w+" \{(.*?)\n\}', tf.read_text(), re.S):
            if "for_each" in block:
                continue  # covered by vms.tf above
            hostname = re.search(r'hostname\s*=\s*"([^"]+)"', block)
            ip = value(block, "ip_address", "ip")
            mac = value(block, "mac_address", "mac")
            if mac is None and "truenas_scale" in block:
                mac = truenas_mac
            if not (hostname and ip and mac):
                sys.exit(f"can't resolve a reservation in {tf.name}: {block.strip()[:120]}; teach this script")
            add(hostname.group(1), mac, ip)

    return sorted(found, key=lambda r: tuple(int(o) for o in r["ip"].split(".")))


def main():
    want = from_tofu()
    for field in ("ip", "mac"):
        seen = [r[field] for r in want]
        dups = sorted({v for v in seen if seen.count(v) > 1})
        if dups:
            sys.exit(f"duplicate {field} in OpenTofu reservations: {dups} (Kea would reject its whole config)")
    if "--write" in sys.argv:
        JSON_PATH.write_text(json.dumps(want, indent=2) + "\n")
        print(f"wrote {len(want)} reservations to {JSON_PATH.relative_to(NIXOS)}")
        return
    # The dynamic pool(s) must match too.
    norm = lambda r: tuple(x.strip() for x in r.split("-"))
    tf_pools = re.search(r'pools\s*=\s*\[([^\]]*)\]', (TF / "opnsense.tf").read_text()).group(1)
    nix_pools = re.search(r'pool = \[([^\]]*)\]', (NIXOS / "hosts" / "gw" / "default.nix").read_text()).group(1)
    tf_set = sorted(norm(p) for p in re.findall(r'"([^"]+)"', tf_pools))
    nix_set = sorted(norm(p) for p in re.findall(r'"([^"]+)"', nix_pools))
    if tf_set != nix_set:
        sys.exit(f"Kea pool differs: OpenTofu {tf_set} vs gw {nix_set}")
    have = json.loads(JSON_PATH.read_text())
    if have == want:
        print(f"{len(want)} reservations match OpenTofu")
        return
    have_set = {json.dumps(r, sort_keys=True) for r in have}
    want_set = {json.dumps(r, sort_keys=True) for r in want}
    for r in sorted(want_set - have_set):
        print(f"missing from JSON: {r}")
    for r in sorted(have_set - want_set):
        print(f"not in OpenTofu:   {r}")
    sys.exit("dhcp-reservations.json is out of sync: run infra/nixos/scripts/check-reservations.py --write")


if __name__ == "__main__":
    main()
