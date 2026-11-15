# The home router: PPPoE (or DHCP) uplink, a bridged LAN, NAT, an nftables
# firewall, Kea DHCP and its exporter. IPv4 only for now.
#
# Firewall policy: drop by default in both directions.
#   - The router accepts management traffic only from the LAN (lan.allowedTCPPorts).
#   - LAN -> WAN is allowed and masqueraded.
#   - WAN -> LAN is allowed only for portForwards.
#   - Drops are logged (rate-limited) to the kernel log with an "nft-drop-" prefix.
{ config, lib, ... }:
let
  cfg = config.homelab.router;
  inherit (lib) mkOption types;

  wanIf = if cfg.wan.type == "pppoe" then "ppp0" else cfg.wan.interface;
  lanIf = "br-lan";
  prefixLength = lib.last (lib.splitString "/" cfg.lan.subnet);
  ports = ps: lib.concatMapStringsSep ", " toString ps;

  forwardRules = lib.concatMapStrings (f: ''
    iifname "${wanIf}" ${f.proto} dport ${toString f.port} dnat to ${f.to}:${toString (if f.toPort == null then f.port else f.toPort)}${lib.optionalString (f.description != "") " comment \"${f.description}\""}
  '') cfg.portForwards;
in
{
  options.homelab.router = {
    enable = lib.mkEnableOption "the home router (NAT, firewall, DHCP)";

    wan = {
      interface = mkOption {
        type = types.str;
        description = "The physical uplink NIC (the PPPoE carrier when type is pppoe).";
      };
      type = mkOption {
        type = types.enum [
          "pppoe"
          "dhcp"
        ];
        default = "pppoe";
      };
      pppoe = {
        optionsFile = mkOption {
          type = types.str;
          description = ''
            A root-only file with the pppd `user "..."` and `password "..."` lines, read at
            runtime (sops) so the credentials never reach the Nix store.
          '';
        };
        mtu = mkOption {
          type = types.int;
          default = 1492;
          description = "PPP MTU/MRU. 1492 = 1500 minus the 8-byte PPPoE header.";
        };
      };
    };

    lan = {
      interfaces = mkOption {
        type = types.listOf types.str;
        description = "NICs bridged into br-lan.";
      };
      subnet = mkOption {
        type = types.str;
        example = "192.168.1.0/24";
      };
      address = mkOption {
        type = types.str;
        example = "192.168.1.1";
        description = "The router's address on the LAN, i.e. the clients' gateway.";
      };
      allowedTCPPorts = mkOption {
        type = types.listOf types.port;
        # ssh, node-exporter, kea-exporter
        default = [
          22
          9100
          9547
        ];
        description = "Router services reachable from the LAN. DHCP (udp/67) and ICMP are always allowed.";
      };
    };

    dhcp = {
      pool = mkOption {
        type = types.str;
        example = "192.168.1.100 - 192.168.1.199";
      };
      dnsServers = mkOption {
        type = types.listOf types.str;
        default = [
          "1.1.1.1"
          "8.8.8.8"
        ];
      };
      # Kea's default is 4000s; clients renew at half of it. Android schedules that
      # renewal as a wakeup alarm, which woke the Formovie projector every ~33 min.
      leaseTime = mkOption {
        type = types.int;
        default = 604800;
        description = "Lease lifetime in seconds (default 7 days).";
      };
      reservations = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              hostname = mkOption { type = types.str; };
              mac = mkOption { type = types.str; };
              ip = mkOption { type = types.str; };
            };
          }
        );
        default = [ ];
      };
    };

    portForwards = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            proto = mkOption {
              type = types.enum [
                "tcp"
                "udp"
              ];
            };
            port = mkOption { type = types.port; };
            to = mkOption {
              type = types.str;
              description = "LAN address to forward to.";
            };
            toPort = mkOption {
              type = types.nullOr types.port;
              default = null;
              description = "Port on the LAN host; defaults to `port`.";
            };
            description = mkOption {
              type = types.str;
              default = "";
            };
          };
        }
      );
      default = [ ];
    };

    extraInputRules = mkOption {
      type = types.lines;
      default = "";
      description = "Extra nftables rules for the input chain, evaluated before the drop.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernel.sysctl = {
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv6.conf.all.forwarding" = 0;
    };

    networking = {
      useNetworkd = true;
      useDHCP = false;
      # The nftables ruleset below is the whole firewall.
      firewall.enable = false;
      nameservers = cfg.dhcp.dnsServers;
      nftables = {
        enable = true;
        ruleset = ''
          table inet filter {
            chain input {
              type filter hook input priority filter; policy drop;
              ct state vmap { established : accept, related : accept, invalid : drop }
              iifname "lo" accept
              iifname "${lanIf}" jump lan_input
              ${cfg.extraInputRules}
              # Broadcast/multicast chatter (LLMNR, mDNS, the ISP's DHCP) isn't worth logging.
              meta pkttype { broadcast, multicast } drop
              limit rate 5/second log prefix "nft-drop-input: " level info
            }

            chain lan_input {
              meta l4proto { icmp, ipv6-icmp } accept
              udp dport 67 accept
              ${lib.optionalString (cfg.lan.allowedTCPPorts != [ ]) "tcp dport { ${ports cfg.lan.allowedTCPPorts} } accept"}
            }

            chain forward {
              type filter hook forward priority filter; policy drop;
              # PPPoE has a smaller MTU: clamp the TCP MSS so large packets don't black-hole.
              tcp flags syn tcp option maxseg size set rt mtu
              ct state vmap { established : accept, related : accept, invalid : drop }
              iifname "${lanIf}" oifname "${wanIf}" accept
              # Port forwards (DNAT'd in table ip nat).
              ct status dnat accept
              limit rate 5/second log prefix "nft-drop-forward: " level info
            }
          }

          table ip nat {
            chain prerouting {
              type nat hook prerouting priority dstnat; policy accept;
              ${forwardRules}
            }

            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              oifname "${wanIf}" masquerade
            }
          }
        '';
      };
    };

    systemd.network = {
      enable = true;
      netdevs."20-br-lan".netdevConfig = {
        Kind = "bridge";
        Name = lanIf;
      };
      networks = {
        "10-wan" = {
          matchConfig.Name = cfg.wan.interface;
          networkConfig = {
            LinkLocalAddressing = "no";
            IPv6AcceptRA = false;
          }
          // lib.optionalAttrs (cfg.wan.type == "dhcp") { DHCP = "ipv4"; };
          dhcpV4Config = lib.mkIf (cfg.wan.type == "dhcp") { UseDNS = false; };
          linkConfig.RequiredForOnline = if cfg.wan.type == "dhcp" then "routable" else "carrier";
        };
        "30-lan-ports" = {
          matchConfig.Name = lib.concatStringsSep " " cfg.lan.interfaces;
          networkConfig = {
            Bridge = lanIf;
            LinkLocalAddressing = "no";
          };
          linkConfig.RequiredForOnline = "enslaved";
        };
        "40-br-lan" = {
          matchConfig.Name = lanIf;
          address = [ "${cfg.lan.address}/${prefixLength}" ];
          networkConfig = {
            ConfigureWithoutCarrier = true;
            LinkLocalAddressing = "no";
            IPv6AcceptRA = false;
          };
          linkConfig.RequiredForOnline = "no";
        };
      };
    };

    # pppd brings up ppp0 and its default route; networkd leaves ppp0 alone.
    services.pppd = lib.mkIf (cfg.wan.type == "pppoe") {
      enable = true;
      peers.wan.config = ''
        plugin pppoe.so
        nic-${cfg.wan.interface}
        file ${cfg.wan.pppoe.optionsFile}
        unit 0
        noauth
        hide-password
        noipdefault
        defaultroute
        noipv6
        persist
        maxfail 0
        holdoff 5
        lcp-echo-interval 10
        lcp-echo-failure 6
        mtu ${toString cfg.wan.pppoe.mtu}
        mru ${toString cfg.wan.pppoe.mtu}
      '';
    };

    services.kea.dhcp4 = {
      enable = true;
      settings = {
        interfaces-config = {
          interfaces = [ lanIf ];
          # br-lan can come up after Kea; keep retrying instead of serving nothing.
          service-sockets-max-retries = 60;
          service-sockets-retry-wait-time = 5000;
        };
        lease-database = {
          type = "memfile";
          persist = true;
          name = "/var/lib/kea/dhcp4.leases";
        };
        control-socket = {
          socket-type = "unix";
          socket-name = "/run/kea/dhcp4.sock";
        };
        valid-lifetime = cfg.dhcp.leaseTime;
        subnet4 = [
          {
            id = 1;
            subnet = cfg.lan.subnet;
            pools = [ { pool = cfg.dhcp.pool; } ];
            option-data = [
              {
                name = "routers";
                data = cfg.lan.address;
              }
              {
                name = "domain-name-servers";
                data = lib.concatStringsSep ", " cfg.dhcp.dnsServers;
              }
            ];
            reservations = map (r: {
              hw-address = lib.toLower r.mac;
              ip-address = r.ip;
              inherit (r) hostname;
            }) cfg.dhcp.reservations;
          }
        ];
      };
    };

    services.prometheus.exporters.kea = {
      enable = true;
      targets = [ "/run/kea/dhcp4.sock" ];
    };
    # Kea 3 refuses a control socket in a directory looser than 0750, and the
    # exporter also declares /run/kea (default 0755), so whichever starts first wins.
    systemd.services.kea-dhcp4-server.serviceConfig.RuntimeDirectoryMode = "0750";
    systemd.services.prometheus-kea-exporter.serviceConfig.RuntimeDirectoryMode = "0750";
  };
}
