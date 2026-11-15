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


def from_tofu():
    found = {}

    def add(hostname, mac, ip):
        found[ip] = {"hostname": hostname, "mac": mac.lower(), "ip": ip}

    for line in (TF / "vms.tf").read_text().splitlines():
        m = re.match(r'\s*([\w-]+)\s*=\s*\{.*\bip\s*=\s*"([\d.]+)".*\bmac\s*=\s*"([0-9A-Fa-f:]+)"', line)
        if m:
            add(m.group(1), m.group(3), m.group(2))

    truenas_mac = re.search(r'mac_address\s*=\s*"([0-9A-Fa-f:]+)"', (TF / "truenas-scale.tf").read_text()).group(1)

    opnsense = (TF / "opnsense.tf").read_text()
    for block in re.findall(r'resource "opnsense_kea_dhcpv4_reservation" "\w+" \{(.*?)\n\}', opnsense, re.S):
        ip = re.search(r'ip_address\s*=\s*"([\d.]+)"', block)
        hostname = re.search(r'hostname\s*=\s*"([^"]+)"', block)
        if not ip or not hostname:
            continue  # the for_each VM blocks, covered by vms.tf above
        mac = re.search(r'mac_address\s*=\s*"([0-9A-Fa-f:]+)"', block)
        if mac:
            add(hostname.group(1), mac.group(1), ip.group(1))
        elif "truenas_scale" in block:
            add(hostname.group(1), truenas_mac, ip.group(1))
        else:
            sys.exit(f"don't know the MAC for reservation {hostname.group(1)}; teach this script")

    return sorted(found.values(), key=lambda r: tuple(int(o) for o in r["ip"].split(".")))


def main():
    want = from_tofu()
    if "--write" in sys.argv:
        JSON_PATH.write_text(json.dumps(want, indent=2) + "\n")
        print(f"wrote {len(want)} reservations to {JSON_PATH.relative_to(NIXOS)}")
        return
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
