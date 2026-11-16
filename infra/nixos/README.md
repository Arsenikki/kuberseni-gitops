# infra/nixos: the NixOS router

`gw` is a NixOS VM meant to replace OPNSense (Proxmox VM 100 on the `router` node). The whole router lives in this directory, in git:

- PPPoE uplink
- bridged LAN
- NAT and the nftables firewall
- Kea DHCP with the LAN's reservations
- Unbound DNS forwarder on 192.168.1.1
- Tailscale: subnet router for the LAN and an exit node, replacing Tailscale on OPNSense
- exporters

**Status: not deployed.** OPNSense is still the router, and `infra/terraform/opnsense.tf` is still the source of truth for DHCP.

| Path | What |
|---|---|
| `modules/router.nix` | The router itself (`homelab.router.*` options) |
| `hosts/common.nix` | Shared by all hosts: Proxmox image, SSH keys, node-exporter, nix gc |
| `hosts/gw/` | The real router: NIC layout matching OPNSense, PPPoE, reservations |
| `hosts/gw-staging/` | Same router on a throwaway VM, with DHCP WAN and an isolated LAN (`vmbr99`) |
| `tests/router.nix` | VM test: PPPoE/CHAP to a fake ISP, DHCP reservation, NAT, port forward, WAN→LAN blocked, drop logging, Kea exporter, and Tailscale via headscale (remote device → LAN, exit node) |
| `scripts/deploy.sh` | Deploy with a dead-man switch (`task nixos:deploy HOST=gw`) |
| `scripts/check-reservations.py` | CI check that `hosts/gw/dhcp-reservations.json` matches OpenTofu |
| `scripts/proxmox/` | Run on the `router` node: `gw-prepare.sh`, `gw-cutover.sh`, `gw-rollback.sh` (see Switchover) |

## Firewall policy

Both directions drop by default.

- **The router** accepts SSH (22), node-exporter (9100) and kea-exporter (9547) from the LAN only, plus DHCP and ICMP.
- **LAN → WAN** is allowed and masqueraded.
- **WAN → LAN** is allowed only for `portForwards`.
- **Tailscale:** tailnet → LAN (masqueraded, so LAN hosts see 192.168.1.1), tailnet → internet (exit node), and LAN → tailnet are allowed. UDP 41641 is open on the WAN for direct connections. tailscaled runs with `--netfilter-mode=off`; these rules are in our ruleset instead.
- **Drops** are logged at a limited rate with the prefixes `nft-drop-input:` and `nft-drop-forward:`.

The stack is IPv4 only for now.

## CI

`.github/workflows/nixos.yaml` runs `nix flake check` on every PR. It builds both hosts and runs the router VM test on a KVM runner, and it checks the reservations against OpenTofu. To get the first-install images (`.vma.zst`), run the workflow manually with *images*.

## Deploying

Run `task nixos:deploy HOST=gw` (or `scripts/deploy.sh gw <rev>`). It deploys only commits on `origin/main` to `gw` (any pushed commit to `gw-staging`) and needs nothing but SSH. Steps:

1. Build the commit on the host (`nixos-rebuild build`). This changes nothing; if it fails, the script stops.
2. Arm a 10-minute reboot timer on the host (`DEADMAN=` to change).
3. Activate with `nixos-rebuild test`. This doesn't touch the bootloader.
4. Confirm that SSH and internet access still work.
5. If they do, disarm the timer and run `switch`. If they don't, the timer reboots the host into the previous generation.

Tried on `gw-staging` on 2026-11-15: a deploy takes about 2 minutes, and the timer's reboot brought the host back cleanly.

The Proxmox console (`qm terminal`) and VM snapshots are the last-resort way back in.

## Switchover from OPNSense

Everything runs on the Proxmox `router` node (192.168.1.10) from `/root/gw/` (copies of `scripts/proxmox/`). The switchover works without the internet or an agent.

### What gw takes over from OPNSense

Checked in OPNSense's config.xml on 2026-11-15:

| OPNSense | gw |
|---|---|
| PPPoE on vtnet0, untagged (Onestream on Vodafone) | `pppd` on `wan`; credentials in `hosts/gw/secrets.yaml` |
| LAN bridge0 = vtnet1+2+3, 192.168.1.1/24 | `br-lan` = lan0-2, same IP. The NIC and bridge MACs are copied, so clients' ARP caches stay valid |
| Kea DHCP: pool .100-.199, reservations, 7-day leases | Same. Current leases are copied at switchover |
| Unbound, forwarding to 1.1.1.1 / 8.8.8.8 (the Proxmox hosts use it) | Unbound on 192.168.1.1, same forwarders |
| Tailscale 1.76 (node `opnsense`, route 192.168.1.0/24) | Same node: its state is copied, so the route stays approved. The exit node is new and needs one approval in the admin console |
| No port forwards; LAN allow-all; nothing inbound from WAN | Same |
| CrowdSec, radvd (IPv6 ULA) | Not carried over (no inbound services; IPv4 only) |

### Steps

1. **Prepare (no downtime).** `gw-prepare.sh <vzdump-qemu-gw.vma.zst> < age-key.txt` installs gw as VM 101, stopped, with its age key on its disk.
2. **Switch (a few minutes without internet).** `systemd-run --unit=gw-cutover /root/gw/gw-cutover.sh`, then follow it with `journalctl -fu gw-cutover`. It:
   - snapshots OPNSense
   - copies the DHCP leases and the Tailscale state
   - shuts OPNSense down cleanly
   - starts gw
   - waits up to 10 minutes for PPPoE, internet and DNS to work

   If they don't, **it switches back to OPNSense by itself**. If they do, gw starts on boot instead of OPNSense.
3. **Roll back any time:** `/root/gw/gw-rollback.sh`, or by hand in the Proxmox web UI: stop VM 101 `gw`, start VM 100 `OPNSense`.

### If something goes wrong and there's no internet

You don't need a cable or a monitor.

- **The LAN and Wi-Fi keep working without the router.** The switch and the U6 Pro don't depend on it, and your devices keep their DHCP address for days (7-day leases).
- **On a laptop or phone on Wi-Fi**, open **https://192.168.1.10:8006** (the Proxmox web UI for the `router` node). Then either:
  - **router → Shell**, and run `/root/gw/gw-rollback.sh`; or
  - VM 101 `gw` → **Stop**, then VM 100 `OPNSense` → **Start**.
- **If a device has no IP address**, give it a manual one: 192.168.1.250, mask 255.255.255.0, no gateway needed.
- **OPNSense is unchanged.** It was only shut down, and its pre-switchover snapshot `pre-gw-cutover` is there too.

### Staging

Staging has run on `nas` since 2026-11-15:

- **VM 990 `gw-staging`** gets its WAN address, 192.168.1.108, from OPNSense by DHCP.
- **Container 991 `gw-staging-client`** is on `vmbr99`.

`vmbr99` was created at runtime (`ip link add vmbr99 type bridge`), so it is gone after a `nas` reboot. Recreate it before starting 990 or 991.

To restore a VM from an image: `qmrestore <file>.vma.zst <vmid> --storage local-lvm`, then `qm set <vmid> --delete ide2` (the image adds an unused cloud-init drive).

### After the switchover

- Remove the OPNSense resources from OpenTofu and make `dhcp-reservations.json` the source of truth.
- Point the cluster's Alloy at gw's exporters and ship its journal to Loki.
- Optional: approve gw as an exit node in the Tailscale admin console.
