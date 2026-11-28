# The home router: PPPoE (or DHCP) uplink, a bridged LAN, NAT, an nftables
# firewall, Kea DHCP and its exporter, an Unbound DNS forwarder, and optionally
# Tailscale (subnet router for the LAN + exit node). IPv4 only for now.
#
# Firewall policy: drop by default in both directions.
#   - The router accepts management traffic and DNS only from the LAN (lan.allowedTCPPorts).
#   - LAN -> WAN is allowed and masqueraded.
#   - WAN -> LAN is allowed only for portForwards.
#   - Tailscale: tailnet -> LAN/WAN (subnet router, exit node) and LAN -> tailnet are
#     allowed. The tailnet's own policy decides which peers may use them.
#   - Drops are logged (rate-limited) to the kernel log with an "nft-drop-" prefix.
{ config, lib, ... }:
let
  cfg = config.homelab.router;
  inherit (lib) mkOption types;

  wanIf = if cfg.wan.type == "pppoe" then "ppp0" else cfg.wan.interface;
  lanIf = "br-lan";
  prefixLength = lib.last (lib.splitString "/" cfg.lan.subnet);
  ports = ps: lib.concatMapStringsSep ", " toString ps;

  ts = cfg.tailscale;
  tsIf = "tailscale0";
  # Applied on every start (`tailscale set`), so changes here reach a logged-in node.
  # --netfilter-mode=off: tailscaled would otherwise write its own nftables rules,
  # which a reload of our ruleset flushes. It has to be in the `set` flags: the up
  # flags only run when logging in with an auth key, and gw takes over an existing node.
  tsFlags = [
    "--advertise-routes=${cfg.lan.subnet}"
    "--accept-dns=false"
    "--netfilter-mode=off"
  ]
  ++ lib.optional ts.exitNode "--advertise-exit-node";

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
      macAddress = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          MAC address for br-lan. Reusing the old router's LAN MAC means clients'
          ARP caches for the gateway stay valid across a switchover.
        '';
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
        type = types.either types.str (types.listOf types.str);
        example = [
          "192.168.1.100 - 192.168.1.149"
          "192.168.1.180 - 192.168.1.199"
        ];
        description = "Dynamic range(s) handed out by Kea.";
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
              dnsServers = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Per-reservation DNS servers (DHCP option 6); empty inherits dhcp.dnsServers.";
              };
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

    tailscale = {
      enable = lib.mkEnableOption "Tailscale: subnet router for the LAN and (optionally) an exit node";
      authKeyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Runtime file (sops) with a tagged auth key, used only for the first login.
          The node then stays logged in via /var/lib/tailscale. null: log in some other
          way, e.g. by copying an existing node's tailscaled.state.
        '';
      };
      loginServer = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Control server URL; null means Tailscale's own.";
      };
      exitNode = mkOption {
        type = types.bool;
        default = true;
        description = "Advertise the router as an exit node.";
      };
      snatSubnetRoutes = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Masquerade tailnet traffic into the LAN, so LAN hosts see the router's address
          rather than a 100.64.0.0/10 one. Tailscale's default, and what OPNSense did.
        '';
      };
    };

    extraInputRules = mkOption {
      type = types.lines;
      default = "";
      description = "Extra nftables rules for the input chain, evaluated before the drop.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Kea rejects its whole config on a duplicate reservation, which stops DHCP for
    # everyone (happened on OPNSense on 2026-11-14). Fail the build instead.
    assertions =
      let
        dups =
          key:
          lib.attrNames (
            lib.filterAttrs (_: n: n > 1) (
              lib.foldl' (acc: r: acc // { ${key r} = (acc.${key r} or 0) + 1; }) { } cfg.dhcp.reservations
            )
          );
      in
      [
        {
          assertion = dups (r: r.ip) == [ ];
          message = "homelab.router.dhcp.reservations: duplicate IPs: ${toString (dups (r: r.ip))}";
        }
        {
          assertion = dups (r: lib.toLower r.mac) == [ ];
          message = "homelab.router.dhcp.reservations: duplicate MACs: ${toString (dups (r: lib.toLower r.mac))}";
        }
      ];

    boot.kernel.sysctl = {
      "net.ipv4.conf.all.forwarding" = 1;
    };

    # Unbound is the DNS server and the router resolves via the upstreams directly, so
    # systemd-resolved (on by default with networkd) only added LLMNR/mDNS listeners
    # on every interface. The firewall blocked them, but they had no reason to run.
    services.resolved.enable = false;

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
              ${lib.optionalString ts.enable ''
                iifname "${tsIf}" jump lan_input
                # Direct (peer-to-peer) WireGuard connections instead of DERP relays.
                iifname "${wanIf}" udp dport ${toString config.services.tailscale.port} accept
              ''}
              ${cfg.extraInputRules}
              # Broadcast/multicast chatter (LLMNR, mDNS, the ISP's DHCP) isn't worth logging.
              meta pkttype { broadcast, multicast } drop
              # The internet scans the WAN address all day: count those drops instead
              # of logging them (`nft list counter inet filter wan_drops`).
              iifname "${wanIf}" counter name wan_drops drop
              limit rate 5/second log prefix "nft-drop-input: " level info
            }

            counter wan_drops { }

            chain lan_input {
              meta l4proto { icmp, ipv6-icmp } accept
              udp dport 67 accept
              meta l4proto { tcp, udp } th dport 53 accept
              ${lib.optionalString (cfg.lan.allowedTCPPorts != [ ]) "tcp dport { ${ports cfg.lan.allowedTCPPorts} } accept"}
            }

            chain forward {
              type filter hook forward priority filter; policy drop;
              # PPPoE has a smaller MTU: clamp the TCP MSS both ways, so neither end
              # sends segments that only fit through PMTU discovery.
              ${if cfg.wan.type == "pppoe" then ''
                oifname "${wanIf}" tcp flags syn tcp option maxseg size set ${toString (cfg.wan.pppoe.mtu - 40)}
                iifname "${wanIf}" tcp flags syn tcp option maxseg size set ${toString (cfg.wan.pppoe.mtu - 40)}
              '' else "tcp flags syn tcp option maxseg size set rt mtu"}
              ct state vmap { established : accept, related : accept, invalid : drop }
              iifname "${lanIf}" oifname "${wanIf}" accept
              ${lib.optionalString ts.enable ''
                iifname "${tsIf}" oifname "${lanIf}" accept
                iifname "${lanIf}" oifname "${tsIf}" accept
                ${lib.optionalString ts.exitNode ''iifname "${tsIf}" oifname "${wanIf}" accept''}
              ''}
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
              ${lib.optionalString ts.enable ''
                # LAN -> tailnet: peers only route 100.64.0.0/10 back, not the LAN subnet.
                oifname "${tsIf}" masquerade
                ${lib.optionalString ts.snatSubnetRoutes ''oifname "${lanIf}" ip saddr 100.64.0.0/10 masquerade''}
              ''}
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
      }
      // lib.optionalAttrs (cfg.lan.macAddress != null) { MACAddress = cfg.lan.macAddress; };
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

    # A nixos-rebuild evaluating nixpkgs on this small VM must not take the router
    # down with it: compressed swap, and the kernel kills anything before these.
    zramSwap.enable = true;
    systemd.services = lib.mkMerge [
      (lib.genAttrs (
        [
          "kea-dhcp4-server"
          "unbound"
          "systemd-networkd"
        ]
        ++ lib.optional (cfg.wan.type == "pppoe") "pppd-wan"
        ++ lib.optional ts.enable "tailscaled"
      ) (_: { serviceConfig.OOMScoreAdjust = -900; }))
      (lib.mkIf (cfg.wan.type == "pppoe") {
        # The ISP can take minutes to accept a new session (e.g. while it still holds
        # the old one), and pppd is ordered before network.target: don't let systemd
        # kill it every 90s while it waits.
        pppd-wan.serviceConfig.TimeoutStartSec = "10min";
      })
      {
        # Kea 3 refuses a control socket in a directory looser than 0750, and the
        # exporter also declares /run/kea (default 0755), so whichever starts first wins.
        kea-dhcp4-server.serviceConfig.RuntimeDirectoryMode = "0750";
        prometheus-kea-exporter.serviceConfig.RuntimeDirectoryMode = "0750";
      }
    ];

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

    # DNS forwarder on the LAN address. DHCP clients get dhcp.dnsServers directly, but
    # hosts with static config (the Proxmox nodes) use the router for DNS.
    services.unbound = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        server = {
          interface = [
            "127.0.0.1"
            cfg.lan.address
          ];
          # br-lan may not have its address yet when Unbound starts.
          ip-freebind = true;
          access-control = [
            "127.0.0.0/8 allow"
            "${cfg.lan.subnet} allow"
            "100.64.0.0/10 allow"
          ];
        };
        forward-zone = [
          {
            name = ".";
            forward-addr = cfg.dhcp.dnsServers;
          }
        ];
      };
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
            pools = map (pool: { inherit pool; }) (lib.toList cfg.dhcp.pool);
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
            reservations = map (
              r:
              {
                hw-address = lib.toLower r.mac;
                ip-address = r.ip;
                inherit (r) hostname;
              }
              // lib.optionalAttrs (r.dnsServers != [ ]) {
                option-data = [
                  {
                    name = "domain-name-servers";
                    data = lib.concatStringsSep ", " r.dnsServers;
                  }
                ];
              }
            ) cfg.dhcp.reservations;
          }
        ];
      };
    };

    # The rules tailscaled needs are in the ruleset above (see tsFlags).
    services.tailscale = lib.mkIf ts.enable {
      enable = true;
      useRoutingFeatures = "server";
      inherit (ts) authKeyFile;
      extraUpFlags =
        tsFlags
        ++ lib.optional (ts.loginServer != null) "--login-server=${ts.loginServer}";
      extraSetFlags = tsFlags;
    };

    services.prometheus.exporters.kea = {
      enable = true;
      targets = [ "/run/kea/dhcp4.sock" ];
    };
  };
}
