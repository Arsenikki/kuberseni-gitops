# infra/nixos: the NixOS router

`gw` is a NixOS VM meant to replace OPNSense (Proxmox VM 100 on the `router` node). The whole router lives in this directory, in git:

- PPPoE uplink
- bridged LAN
- NAT and the nftables firewall
- Kea DHCP with the LAN's reservations
- Unbound DNS forwarder on 192.168.1.1
- Tailscale: subnet router for the LAN and an exit node, replacing Tailscale on OPNSense
- exporters

**Status: live since 2026-11-23** (switchover 16:00–16:07 UTC). gw is VM 101 on `router` and starts on boot; OPNSense (VM 100) is stopped and kept for rollback (`/root/gw/gw-rollback.sh`). Until OPNSense is removed from OpenTofu, `infra/terraform/opnsense.tf` and `hosts/gw/dhcp-reservations.json` must match (CI checks); **don't run `tofu plan/apply`** meanwhile, it would fail against the stopped OPNSense.

| Path | What |
|---|---|
| `modules/router.nix` | The router itself (`homelab.router.*` options) |
| `hosts/common.nix` | Shared by all hosts: Proxmox image, SSH keys, node-exporter, nix gc |
| `hosts/gw/` | The real router: NIC layout matching OPNSense, PPPoE, reservations |
| `hosts/gw-staging/` | Same router on a throwaway VM, with DHCP WAN and an isolated LAN (`vmbr99`) |
| `tests/router.nix` | VM test: PPPoE/CHAP to a fake ISP, DHCP reservation, NAT, port forward, WAN→LAN blocked, drop logging, Kea exporter, and Tailscale via headscale (remote device → LAN, exit node) |
| `scripts/deploy.sh` | Deploy with a dead-man switch (`task nixos:deploy HOST=gw`) |
| `scripts/check-reservations.py` | CI check that `hosts/gw/dhcp-reservations.json` matches OpenTofu |
| `scripts/proxmox/` | Run on the `router` node: `router-host-net.sh` (host bridges/IPv6), `gw-prepare.sh`, `gw-cutover.sh`, `gw-rollback.sh` (see Switchover) |

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

Run `task nixos:deploy HOST=gw` (or `scripts/deploy.sh gw <rev>`). It needs SSH and `gh`.

- **`gw`:** only commits from a PR **merged by the owner** (Arsenikki). Jeeves can auto-merge low-risk PRs and `main` requires no reviews, so being on `main` isn't enough.
- **`gw-staging`:** any pushed commit.

Steps:

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

0. **Host network (on the `router` node, before switching).** Run `/root/gw/router-host-net.sh harden`: IPv6 goes off on the WAN bridge and no router adverts are accepted, with no traffic impact. Then run `/root/gw/router-host-net.sh merge-bridges`: the Wi-Fi port joins the LAN bridge, Wi-Fi blips for about a second, and from then on Wi-Fi reaches Proxmox even with no router VM running. See the script header for why.
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

You don't need a monitor. Whether you need a cable depends on where your device connects.

**Topology catch (as of 2026-11-16):**
- The U6 Pro hangs off `router`'s `enp4s0` (`vmbr2`).
- The Proxmox host (.10), the Flex Mini and the servers are on `enp3s0` (`vmbr1`).
- Only the router VM's LAN bridge joins the two sides. So **Wi-Fi can reach Proxmox only while a router VM (OPNSense or gw) is running.** If gw runs but PPPoE fails, that's fine. If neither router VM runs, it isn't.

**What to do:**
- **From Wi-Fi, if a router VM is up**, or **from a device cabled to the Flex Mini** in any case: open **https://192.168.1.10:8006** (the Proxmox web UI for the `router` node). Then either:
  - **router → Shell**, and run `/root/gw/gw-rollback.sh`; or
  - VM 101 `gw` → **Stop**, then VM 100 `OPNSense` → **Start**.
- **Devices keep their DHCP address for days** (7-day leases). If a device has none, give it a manual one: 192.168.1.250, mask 255.255.255.0, no gateway needed.
- **OPNSense is unchanged.** It was only shut down, and its pre-switchover snapshot `pre-gw-cutover` is there too.
- **gw-cutover.sh rolls back by itself** and needs none of this.

### If the `router` Proxmox host dies

The WAN cable (from the Draytek) only goes into that host, so gw can't simply move to another node. Pick a fallback by how long the box will be down:

1. **Hours to days: let the Draytek route.** Switch the Draytek from bridge/modem mode to router mode with PPPoE, using the ISP login (1Password item `isp-pppoe`, see below). Give it 192.168.1.1/24 on its LAN side and connect it to the Flex Mini.
   - The LAN, Wi-Fi and the cluster keep working, but there's no DHCP. Existing leases last 7 days, and the Draytek's own DHCP server can stand in.
   - Tailscale is gone until gw is back.
2. **Longer: run gw on `nas`.** Restore gw from its image (Actions → *NixOS* → Run workflow with *images*) with `gw-prepare.sh` on `nas`. Take one of `nas`'s four ports out of its LAN bridge and give it to gw as WAN, cabled to the Draytek. Update gw's MACs or NIC names in `hosts/gw` to match.
3. **Whatever happens, keep these where they don't depend on this box:**
   - **The ISP login, in 1Password.** sops alone isn't enough, because decrypting it needs the cluster or paseo-generic. One-time, from a machine with the repo's age key and `op`:
     ```sh
     sops -d --extract '["pppoe"]' infra/nixos/hosts/gw/secrets.yaml | sed -n 's/^user "\(.*\)"$/username=\1/p; s/^password "\(.*\)"$/password=\1/p' |
       xargs op item create --vault homelab --category login --title isp-pppoe
     ```
   - **An offline copy of the repo's master age key** (`kuberseni-gitops-sops-age-key`). It decrypts gw's own key and every other secret.

### If the rollback fails too (escalation ladder)

Work down the list, stopping at the first step that brings the internet back. Save this page to your phone first: once the router is down, nothing on the network can show it to you.

1. **Wait 15 minutes.** `gw-cutover.sh` rolls back by itself within about 12 minutes. A rejected PPPoE login (the ISP still holding the old session) also clears in about 10 minutes.
2. **Proxmox web UI.** Open https://192.168.1.10:8006 from Wi-Fi, or from a laptop cabled to the Flex Mini. After `merge-bridges`, the router box's spare 4th port (`enp5s0`) also works. If your device has no IP address, set 192.168.1.250, mask 255.255.255.0.
   - VM 101 `gw` → **Stop**. VM 100 `OPNSense` → **Start**. Wait 3 minutes.
3. **OPNSense starts but has no internet**, or won't boot: VM 100 → **Snapshots** → `pre-gw-cutover` → **Rollback**, then **Start**.
4. **OPNSense is broken but gw got as far as booting:** try gw instead (VM 100 **Stop**, VM 101 **Start**). If neither gets PPPoE up, the problem is on the ISP side (step 7).
5. **The Proxmox web UI is unreachable** (the host's own network is broken, e.g. by `merge-bridges`): connect a monitor and USB keyboard to the router box and log in as root.
   - Restore the bridges: `cp /etc/network/interfaces.before-merge-* /etc/network/interfaces && ifreload -a`.
   - Optionally undo `harden`: `rm /etc/sysctl.d/90-router-host.conf`. Then go back to step 2.
6. **The router box itself is dead:** let the Draytek route. Switch it from bridge/modem mode to router mode with PPPoE, using the login in 1Password item `isp-pppoe`, and connect its LAN port to the Flex Mini. See "If the router Proxmox host dies".
7. **Nothing works, or PPPoE is refused everywhere:** use a phone hotspot to get online, and call Onestream if PPPoE keeps being refused. The agents run in the cluster and have no internet while the router is down, so they can't help until it's back.

Before switching, check that the 1Password item `isp-pppoe` exists, that you know the Draytek's admin login, and that you have a phone hotspot, a laptop with Ethernet and, ideally, a monitor and keyboard near the router box.

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
