# infra/nixos: the NixOS router

`gw` is a NixOS VM meant to replace OPNSense (Proxmox VM 100 on the `router` node). The whole router lives in this directory, in git:

- PPPoE uplink
- bridged LAN
- NAT and the nftables firewall
- Kea DHCP with the LAN's reservations
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

## Plan

1. **Staging** (running since 2026-11-15 on `nas`): VM 990 `gw-staging` (WAN 192.168.1.108 via DHCP) and container 991 `gw-staging-client` on `vmbr99`. `vmbr99` was created at runtime (`ip link add vmbr99 type bridge`), so it is gone after a `nas` reboot; recreate it before starting 990/991. To restore from an image: `qmrestore <file>.vma.zst <vmid> --storage local-lvm`, then `qm set <vmid> --delete ide2` (an unused cloud-init drive the image adds).
2. **Before cutover:**
   - Copy OPNSense's port forwards and any other rules into `hosts/gw/default.nix`.
   - Restore `gw` (stopped) on the `router` node.
   - Add its age key to `.sops.yaml`.
   - In the Tailscale admin console, create a **tagged auth key** for `tag:router`. In the tailnet policy, add `autoApprovers` so the routes need no clicking:
     ```json
     "tagOwners": { "tag:router": ["autogroup:admin"] },
     "autoApprovers": { "routes": { "192.168.1.0/24": ["tag:router"] }, "exitNode": ["tag:router"] }
     ```
   - Create `hosts/gw/secrets.yaml` with the PPPoE credentials and that key:
     ```yaml
     pppoe: |
       user "..."
       password "..."
     tailscale_authkey: tskey-auth-...
     ```
3. **Cutover.** Snapshot and stop OPNSense (VM 100), then start `gw`. Afterwards, remove the old OPNSense node from the tailnet. The `router` node can't run both: OPNSense takes 8 GB of its 15 GB.
4. **Rollback.** Stop `gw` and start VM 100.
5. **After cutover:**
   - Remove the OPNSense resources from OpenTofu and make `dhcp-reservations.json` the source of truth.
   - Point the cluster's Alloy at gw's exporters and ship its journal to Loki.

### Host age key (sops)

After the first boot, convert the host's SSH key to an age recipient. Add it to `.sops.yaml` in a rule for `infra/nixos/hosts/gw/secrets.yaml`, above the catch-all `infra/` rule:

```sh
ssh root@192.168.1.1 cat /etc/ssh/ssh_host_ed25519_key.pub | nix run nixpkgs#ssh-to-age
```
