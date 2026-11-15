# gw: the home router, a VM on the Proxmox `router` node replacing OPNSense (VM 100).
# Same NIC layout as OPNSense: net0 = WAN (vmbr0, PPPoE), net1-3 = LAN ports
# (vmbr1-3), bridged together into br-lan like OPNSense's LAN bridge.
{ config, lib, ... }:
let
  # Fixed MACs so the NICs get stable names whatever order they probe in.
  nics = {
    wan = "BC:24:11:9A:00:01";
    lan0 = "BC:24:11:9A:00:02";
    lan1 = "BC:24:11:9A:00:03";
    lan2 = "BC:24:11:9A:00:04";
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
      onboot = 1;
      startup = "order=1";
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
    };
    dhcp = {
      pool = "192.168.1.100 - 192.168.1.199";
      # Copied from infra/terraform (opnsense.tf + VM MACs); CI checks they stay in sync
      # (scripts/check-reservations.py) until OpenTofu stops managing OPNSense.
      reservations = lib.importJSON ./dhcp-reservations.json;
    };
    # TODO before cutover: copy OPNSense's port forwards (Firewall > NAT > Port Forward).
    portForwards = [ ];
    # Replaces Tailscale on OPNSense: advertises the LAN and is an exit node. The tailnet
    # policy should auto-approve both for tag:router (see README).
    tailscale = {
      enable = true;
      authKeyFile = "/run/secrets/tailscale_authkey";
    };
  };

  # secrets.yaml (created once the host's age key exists; see README) holds:
  #   pppoe: the pppd `user "..."` and `password "..."` lines. Without it, no internet.
  #   tailscale_authkey: a tag:router auth key. Without it, Tailscale stays logged out.
  sops.secrets = lib.mkIf (builtins.pathExists ./secrets.yaml) {
    pppoe.sopsFile = ./secrets.yaml;
    tailscale_authkey.sopsFile = ./secrets.yaml;
  };
}
