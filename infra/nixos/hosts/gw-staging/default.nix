# gw-staging: the router config on a throwaway VM, for trying changes before gw.
# Its "WAN" is the real LAN (DHCP from the live router) and its LAN is an
# isolated bridge (vmbr99, no physical ports), so its Kea can't hand out
# leases on the real network. Put a test VM on vmbr99 to act as a client.
{ lib, ... }:
let
  nics = {
    wan = "BC:24:11:9A:01:01";
    lan0 = "BC:24:11:9A:01:02";
  };
in
{
  networking.hostName = "gw-staging";

  proxmox = {
    qemuConf = {
      memory = 1536;
      net0 = "virtio=${nics.wan},bridge=vmbr0";
    };
    qemuExtraConf.net1 = "virtio=${nics.lan0},bridge=vmbr99";
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
      type = "dhcp";
    };
    lan = {
      interfaces = [ "lan0" ];
      subnet = "192.168.99.0/24";
      address = "192.168.99.1";
    };
    dhcp.pool = "192.168.99.100 - 192.168.99.199";
    # Its WAN is the home LAN: let the LAN (owner, paseo-generic, monitoring) manage it.
    extraInputRules = ''
      iifname "wan" ip saddr 192.168.1.0/24 tcp dport { 22, 9100, 9547 } accept
      iifname "wan" ip saddr 192.168.1.0/24 meta l4proto icmp accept
    '';
    portForwards = [
      {
        proto = "tcp";
        port = 8080;
        to = "192.168.99.100";
        description = "test client web server";
      }
    ];
  };
}
