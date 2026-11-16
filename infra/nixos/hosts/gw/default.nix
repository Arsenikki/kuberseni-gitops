# gw: the home router, a VM on the Proxmox `router` node replacing OPNSense (VM 100).
# Same NIC layout as OPNSense: net0 = WAN (vmbr0, PPPoE), net1-3 = LAN ports
# (vmbr1-3), bridged together into br-lan like OPNSense's LAN bridge.
#
# The NICs and br-lan reuse OPNSense's MACs, so to the ISP and to every LAN device
# (ARP caches for 192.168.1.1) the switchover is invisible. The two VMs never run
# at the same time (scripts/cutover.sh).
{ config, lib, ... }:
let
  # OPNSense's NIC MACs (qm config 100): vtnet0 = WAN, vtnet1-3 = LAN bridge members.
  nics = {
    wan = "22:AE:AC:99:B5:F0";
    lan0 = "16:41:56:35:70:0E";
    lan1 = "EE:8B:DA:BF:38:E4";
    lan2 = "52:DE:96:AA:D8:6E";
  };
in
{
  networking.hostName = "gw";

  proxmox = {
    qemuConf.net0 = "virtio=${nics.wan},bridge=vmbr0";
    qemuExtraConf = {
      net1 = "virtio=${nics.lan0},bridge=vmbr1";
      net2 = "virtio=${nics.lan1},bridge=vmbr2";
      net3 = "virtio=${nics.lan2},bridge=vmbr3";
      # No onboot/startup here: OPNSense (same MACs, same IP) starts on boot until
      # scripts/proxmox/gw-cutover.sh succeeds, and only that script flips it.
    };
  };

  systemd.network.links = lib.mapAttrs' (
    name: mac:
    lib.nameValuePair "10-${name}" {
      matchConfig.MACAddress = lib.toLower mac;
      linkConfig.Name = name;
    }
  ) nics;

  homelab.router = {
    enable = true;
    wan = {
      interface = "wan";
      type = "pppoe";
      pppoe.optionsFile = "/run/secrets/pppoe";
    };
    lan = {
      interfaces = [
        "lan0"
        "lan1"
        "lan2"
      ];
      subnet = "192.168.1.0/24";
      address = "192.168.1.1";
      # OPNSense's bridge0.
      macAddress = "58:9c:fc:10:f1:79";
    };
    dhcp = {
      pool = "192.168.1.100 - 192.168.1.199";
      # Copied from infra/terraform (opnsense.tf + VM MACs); CI checks they stay in sync
      # (scripts/check-reservations.py) until OpenTofu stops managing OPNSense.
      reservations = lib.importJSON ./dhcp-reservations.json;
    };
    # OPNSense had no port forwards (checked in its config.xml, 2026-11-15).
    portForwards = [ ];
    # Replaces Tailscale on OPNSense (node "opnsense", 192.168.1.0/24). scripts/cutover.sh
    # copies that node's tailscaled.state, so gw takes over the same node and its
    # already-approved route. The exit node is new and needs approving once.
    tailscale.enable = true;
  };

  # pppoe: the pppd `user "..."` and `password "..."` lines (from OPNSense's config).
  sops.secrets.pppoe.sopsFile = ./secrets.yaml;
}
