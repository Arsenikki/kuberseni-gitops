# The home router: PPPoE (or DHCP) uplink, a bridged LAN plus optional VLAN zones,
# NAT, an nftables firewall, Kea DHCP and its exporter, Unbound DNS (optionally with
# a local authoritative zone in Knot, updated by external-dns), an mDNS reflector,
# and optionally Tailscale (subnet router + exit node). IPv4 only for now.
#
# Zones: "lan" is the untagged LAN (management); each entry in `vlans` is a tagged
# VLAN on the same bridge with its own subnet, DHCP and policy.
#
# Firewall policy: drop by default in both directions.
#   - The router accepts management traffic (lan.allowedTCPPorts) from the LAN only;
#     every zone gets DHCP, DNS and ICMP, plus its own allowedTCPPorts.
#   - Every zone with `internet = true` may go out to the WAN (masqueraded).
#   - Zone -> zone only where the source zone lists the target in `canReach`
#     (replies are always allowed). By default the LAN reaches every VLAN and no
#     VLAN reaches anything but the internet.
#   - WAN -> LAN is allowed only for portForwards.
#   - Tailscale: the tailnet reaches every zone and the WAN (subnet router, exit
#     node); the LAN reaches the tailnet. The tailnet's own policy decides who may.
#   - Drops are logged (rate-limited) to the kernel log with an "nft-drop-" prefix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.router;
  inherit (lib) mkOption types;

  wanIf = if cfg.wan.type == "pppoe" then "ppp0" else cfg.wan.interface;
  lanIf = "br-lan";
  prefixLength = lib.last (lib.splitString "/" cfg.lan.subnet);
  ports = ps: lib.concatMapStringsSep ", " toString ps;

  # Zone name -> interface. VLAN interfaces are named after their zone.
  vlanNames = lib.attrNames cfg.vlans;
  zoneIf = { lan = lanIf; } // lib.genAttrs vlanNames (n: n);
  zones = { lan = cfg.lan // { internet = true; }; } // cfg.vlans;
  allZoneIfs = lib.attrValues zoneIf;
  ifSet = ifs: "{ ${lib.concatMapStringsSep ", " (i: "\"${i}\"") ifs} }";
  addrSet = addrs: "{ ${lib.concatStringsSep ", " addrs} }";
  mdnsIfs = lib.mapAttrsToList (n: _: zoneIf.${n}) (lib.filterAttrs (_: z: z.mdns) zones);
  allSubnets = [ cfg.lan.subnet ] ++ lib.mapAttrsToList (_: v: v.subnet) cfg.vlans;
  prefixOf = subnet: lib.last (lib.splitString "/" subnet);

  zone = cfg.dns.localZone;

  reservationType = types.submodule {
    options = {
      hostname = mkOption { type = types.str; };
      mac = mkOption { type = types.str; };
      ip = mkOption { type = types.str; };
    };
  };

  ts = cfg.tailscale;
  tsIf = "tailscale0";
  # Applied on every start (`tailscale set`), so changes here reach a logged-in node.
  # --netfilter-mode=off: tailscaled would otherwise write its own nftables rules,
  # which a reload of our ruleset flushes. It has to be in the `set` flags: the up
  # flags only run when logging in with an auth key, and gw takes over an existing node.
  tsFlags = [
    "--advertise-routes=${lib.concatStringsSep "," allSubnets}"
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
      canReach = mkOption {
        type = types.listOf types.str;
        default = vlanNames;
        defaultText = lib.literalExpression "attrNames config.homelab.router.vlans";
        description = ''Zones the LAN may open connections to ("tailnet" for Tailscale peers).'';
      };
      mdns = mkOption {
        type = types.bool;
        default = false;
        description = "Reflect mDNS between this zone and the other zones that have it on.";
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

    vlans = mkOption {
      default = { };
      description = "Tagged VLAN zones on the LAN bridge, keyed by name (also the interface name).";
      type = types.attrsOf (
        types.submodule {
          options = {
            id = mkOption {
              type = types.ints.between 2 4094;
              description = "802.1Q VLAN id; also the zone's Kea subnet id.";
            };
            subnet = mkOption {
              type = types.str;
              example = "192.168.20.0/24";
            };
            address = mkOption {
              type = types.str;
              example = "192.168.20.1";
            };
            pool = mkOption {
              type = types.either types.str (types.listOf types.str);
              example = "192.168.20.100 - 192.168.20.199";
            };
            reservations = mkOption {
              type = types.listOf reservationType;
              default = [ ];
            };
            internet = mkOption {
              type = types.bool;
              default = true;
            };
            canReach = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = ''Zones this one may open connections to ("lan", other VLANs, "tailnet").'';
            };
            allow = mkOption {
              default = [ ];
              description = ''
                Narrower than canReach: specific addresses (and optionally ports) in another
                zone that this one may open connections to.
              '';
              type = types.listOf (
                types.submodule {
                  options = {
                    to = mkOption {
                      type = types.str;
                      description = "Target zone.";
                    };
                    addresses = mkOption {
                      type = types.listOf types.str;
                      example = [ "192.168.1.220-192.168.1.229" ];
                    };
                    tcpPorts = mkOption {
                      type = types.listOf types.port;
                      default = [ ];
                    };
                    udpPorts = mkOption {
                      type = types.listOf types.port;
                      default = [ ];
                    };
                    description = mkOption {
                      type = types.str;
                      default = "";
                    };
                  };
                }
              );
            };
            mdns = mkOption {
              type = types.bool;
              default = false;
            };
            allowedTCPPorts = mkOption {
              type = types.listOf types.port;
              default = [ ];
              description = "Router services reachable from this zone, besides DHCP, DNS and ICMP.";
            };
          };
        }
      );
    };

    dns = {
      upstreams = mkOption {
        type = types.listOf types.str;
        default = [
          "1.1.1.1"
          "8.8.8.8"
        ];
        description = "Where Unbound forwards everything it isn't authoritative for.";
      };
      localZone = {
        enable = lib.mkEnableOption "a local authoritative zone (Knot), updatable over RFC 2136";
        serve = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Have Unbound answer the zone from Knot. Turn on only once the zone is
            populated: an empty authoritative zone makes every name in it NXDOMAIN.
          '';
        };
        name = mkOption {
          type = types.str;
          example = "arsenikki.casa";
        };
        port = mkOption {
          type = types.port;
          default = 5300;
          description = "Knot's port on 127.0.0.1 and the LAN address (5353 is mDNS).";
        };
        updateKeyFile = mkOption {
          type = types.str;
          description = ''
            Runtime file (sops) with a Knot `key:` section defining the TSIG key that
            may update and transfer the zone (RFC 2136, e.g. external-dns).
          '';
        };
        updateKeyName = mkOption {
          type = types.str;
          default = "external-dns";
        };
        updatesFrom = mkOption {
          type = types.listOf types.str;
          default = [ cfg.lan.subnet ];
          defaultText = lib.literalExpression "[ config.homelab.router.lan.subnet ]";
          description = "Networks allowed to send (TSIG-signed) updates.";
        };
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
        default = cfg.dns.upstreams;
        defaultText = lib.literalExpression "config.homelab.router.dns.upstreams";
        description = "DNS servers handed to LAN clients. VLAN clients always get the router.";
      };
      # Kea's default is 4000s; clients renew at half of it. Android schedules that
      # renewal as a wakeup alarm, which woke the Formovie projector every ~33 min.
      leaseTime = mkOption {
        type = types.int;
        default = 604800;
        description = "Lease lifetime in seconds (default 7 days).";
      };
      reservations = mkOption {
        type = types.listOf reservationType;
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
        allReservations = cfg.dhcp.reservations ++ lib.concatMap (v: v.reservations) (lib.attrValues cfg.vlans);
        dupsIn =
          list: key:
          lib.attrNames (
            lib.filterAttrs (_: n: n > 1) (lib.foldl' (acc: x: acc // { ${key x} = (acc.${key x} or 0) + 1; }) { } list)
          );
        knownZones = [ "lan" "tailnet" ] ++ vlanNames;
      in
      [
        {
          assertion = dupsIn allReservations (r: r.ip) == [ ];
          message = "homelab.router: duplicate reserved IPs: ${toString (dupsIn allReservations (r: r.ip))}";
        }
        {
          # Kea keys host reservations by MAC: one device, one zone.
          assertion = dupsIn allReservations (r: lib.toLower r.mac) == [ ];
          message = "homelab.router: duplicate reserved MACs: ${toString (dupsIn allReservations (r: lib.toLower r.mac))}";
        }
        {
          assertion = dupsIn (lib.attrValues cfg.vlans) (v: toString v.id) == [ ];
          message = "homelab.router.vlans: duplicate VLAN ids";
        }
        {
          assertion = lib.all (n: lib.stringLength n <= 15 && n != "lan" && n != "tailnet") vlanNames;
          message = "homelab.router.vlans: names are interface names (max 15 chars) and can't be lan/tailnet";
        }
        {
          assertion = lib.all (v: lib.all (a: lib.elem a.to ([ "lan" ] ++ vlanNames)) v.allow) (lib.attrValues cfg.vlans);
          message = "homelab.router.vlans.<name>.allow: \"to\" must be lan or a VLAN zone";
        }
        {
          assertion = lib.all (z: lib.all (t: lib.elem t knownZones) z.canReach) (lib.attrValues zones);
          message = "homelab.router: canReach names an unknown zone (known: ${toString knownZones})";
        }
      ];

    boot.kernel.sysctl = {
      "net.ipv4.conf.all.forwarding" = 1;
    };

    networking = {
      useNetworkd = true;
      useDHCP = false;
      # The nftables ruleset below is the whole firewall.
      firewall.enable = false;
      # The router itself resolves via the upstreams, not its own Unbound.
      nameservers = cfg.dns.upstreams;
      nftables = {
        enable = true;
        ruleset = ''
          table inet filter {
            # Strict reverse-path check: drop packets whose source isn't routed back out
            # the interface they came in on (spoofing across zones/WAN). DHCP clients
            # start from 0.0.0.0; tailscale0 uses policy routing, so it's exempt.
            chain rpfilter {
              type filter hook prerouting priority raw; policy accept;
              ip saddr 0.0.0.0 udp dport 67 accept
              ${lib.optionalString ts.enable ''iifname "${tsIf}" accept''}
              fib saddr . iif oif missing counter drop
            }

            chain input {
              type filter hook input priority filter; policy drop;
              ct state vmap { established : accept, related : accept, invalid : drop }
              iifname "lo" accept
              iifname "${lanIf}" jump lan_input
              ${lib.concatMapStrings (n: ''
                iifname "${n}" jump zone_input_${n}
              '') vlanNames}
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
              ${lib.optionalString cfg.lan.mdns "udp dport 5353 accept"}
              ${lib.optionalString zone.enable "ip saddr ${addrSet zone.updatesFrom} meta l4proto { tcp, udp } th dport ${toString zone.port} accept"}
              ${lib.optionalString (cfg.lan.allowedTCPPorts != [ ]) "tcp dport { ${ports cfg.lan.allowedTCPPorts} } accept"}
            }

            ${lib.concatStrings (lib.mapAttrsToList (n: v: ''
              chain zone_input_${n} {
                meta l4proto { icmp, ipv6-icmp } accept
                udp dport 67 accept
                meta l4proto { tcp, udp } th dport 53 accept
                ${lib.optionalString v.mdns "udp dport 5353 accept"}
                ${lib.optionalString (v.allowedTCPPorts != [ ]) "tcp dport { ${ports v.allowedTCPPorts} } accept"}
              }
            '') cfg.vlans)}

            chain forward {
              type filter hook forward priority filter; policy drop;
              # PPPoE has a smaller MTU: clamp the TCP MSS both ways, so neither end
              # sends segments that only fit through PMTU discovery.
              ${if cfg.wan.type == "pppoe" then ''
                oifname "${wanIf}" tcp flags syn tcp option maxseg size set ${toString (cfg.wan.pppoe.mtu - 40)}
                iifname "${wanIf}" tcp flags syn tcp option maxseg size set ${toString (cfg.wan.pppoe.mtu - 40)}
              '' else "tcp flags syn tcp option maxseg size set rt mtu"}
              ct state vmap { established : accept, related : accept, invalid : drop }
              ${lib.concatStrings (lib.mapAttrsToList (n: z: lib.optionalString z.internet ''
                iifname "${zoneIf.${n}}" oifname "${wanIf}" accept
              '') zones)}
              ${lib.concatStrings (lib.mapAttrsToList (n: z: lib.concatMapStrings (t: ''
                iifname "${zoneIf.${n}}" oifname "${if t == "tailnet" then tsIf else zoneIf.${t}}" accept
              '') (lib.filter (t: t != "tailnet" || ts.enable) z.canReach)) zones)}
              ${lib.concatStrings (lib.mapAttrsToList (n: v: lib.concatMapStrings (a:
                let
                  head = ''iifname "${n}" oifname "${zoneIf.${a.to}}" ip daddr ${addrSet a.addresses}'';
                  note = lib.optionalString (a.description != "") '' comment "${a.description}"'';
                in
                if a.tcpPorts == [ ] && a.udpPorts == [ ] then ''
                  ${head} accept${note}
                '' else ''
                  ${lib.optionalString (a.tcpPorts != [ ]) "${head} tcp dport { ${ports a.tcpPorts} } accept${note}"}
                  ${lib.optionalString (a.udpPorts != [ ]) "${head} udp dport { ${ports a.udpPorts} } accept${note}"}
                ''
              ) v.allow) cfg.vlans)}
              ${lib.optionalString ts.enable ''
                iifname "${tsIf}" oifname ${ifSet allZoneIfs} accept
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
                ${lib.optionalString ts.snatSubnetRoutes ''oifname ${ifSet allZoneIfs} ip saddr 100.64.0.0/10 masquerade''}
              ''}
            }
          }
        '';
      };
    };

    systemd.network = {
      enable = true;
      netdevs = {
        "20-br-lan".netdevConfig = {
          Kind = "bridge";
          Name = lanIf;
        }
        // lib.optionalAttrs (cfg.lan.macAddress != null) { MACAddress = cfg.lan.macAddress; };
      }
      // lib.mapAttrs' (
        n: v:
        lib.nameValuePair "30-vlan-${n}" {
          netdevConfig = {
            Kind = "vlan";
            Name = n;
          };
          vlanConfig.Id = v.id;
        }
      ) cfg.vlans;
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
          vlan = vlanNames;
          networkConfig = {
            ConfigureWithoutCarrier = true;
            LinkLocalAddressing = "no";
            IPv6AcceptRA = false;
          };
          linkConfig.RequiredForOnline = "no";
        };
      }
      // lib.mapAttrs' (
        n: v:
        lib.nameValuePair "50-vlan-${n}" {
          matchConfig.Name = n;
          address = [ "${v.address}/${prefixOf v.subnet}" ];
          networkConfig = {
            ConfigureWithoutCarrier = true;
            LinkLocalAddressing = "no";
            IPv6AcceptRA = false;
          };
          linkConfig.RequiredForOnline = "no";
        }
      ) cfg.vlans;
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
          ]
          ++ lib.mapAttrsToList (_: v: v.address) cfg.vlans;
          # br-lan may not have its address yet when Unbound starts.
          ip-freebind = true;
          access-control = [
            "127.0.0.0/8 allow"
            "100.64.0.0/10 allow"
          ]
          ++ map (s: "${s} allow") allSubnets;
          # DNS rebinding protection: public names may not resolve to internal addresses
          # (except the local zone, via private-domain).
          private-address = [
            "10.0.0.0/8"
            "172.16.0.0/12"
            "192.168.0.0/16"
            "169.254.0.0/16"
            "100.64.0.0/10"
          ];
        }
        // lib.optionalAttrs (zone.enable && zone.serve) {
          # The local zone is unsigned (the public one may be signed), and served by Knot
          # on localhost, which Unbound refuses to query by default.
          domain-insecure = [ zone.name ];
          do-not-query-localhost = false;
        }
        # Even before Unbound serves the local zone itself, its public answers are
        # internal addresses: exempt it from the rebinding protection.
        // lib.optionalAttrs zone.enable {
          private-domain = [ zone.name ];
        };
        stub-zone = lib.optional (zone.enable && zone.serve) {
          name = zone.name;
          stub-addr = [ "127.0.0.1@${toString zone.port}" ];
        };
        forward-zone = [
          {
            name = ".";
            forward-addr = cfg.dns.upstreams;
          }
        ];
      };
    };

    services.kea.dhcp4 = {
      enable = true;
      settings = {
        interfaces-config = {
          interfaces = allZoneIfs;
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
        subnet4 =
          let
            subnet =
              {
                id,
                ifname,
                subnet,
                address,
                pool,
                dns,
                reservations,
              }:
              {
                inherit id subnet;
                interface = ifname;
                pools = map (p: { pool = p; }) (lib.toList pool);
                option-data = [
                  {
                    name = "routers";
                    data = address;
                  }
                  {
                    name = "domain-name-servers";
                    data = lib.concatStringsSep ", " dns;
                  }
                ]
                ++ lib.optional (zone.enable && zone.serve) {
                  name = "domain-search";
                  data = zone.name;
                };
                reservations = map (r: {
                  hw-address = lib.toLower r.mac;
                  ip-address = r.ip;
                  inherit (r) hostname;
                }) reservations;
              };
          in
          [
            (subnet {
              id = 1;
              ifname = lanIf;
              inherit (cfg.lan) subnet address;
              inherit (cfg.dhcp) pool reservations;
              dns = cfg.dhcp.dnsServers;
            })
          ]
          ++ lib.mapAttrsToList (
            n: v:
            subnet {
              inherit (v)
                id
                subnet
                address
                pool
                reservations
                ;
              ifname = n;
              dns = [ v.address ];
            }
          ) cfg.vlans;
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

    # Local authoritative zone. Records arrive by TSIG-signed RFC 2136 updates
    # (external-dns in the cluster) and live in Knot's journal; the zone file in the
    # store only seeds the SOA and NS.
    services.knot = lib.mkIf zone.enable {
      enable = true;
      keyFiles = [ zone.updateKeyFile ];
      settings = {
        server.listen = [
          "127.0.0.1@${toString zone.port}"
          "${cfg.lan.address}@${toString zone.port}"
        ];
        acl.updaters = {
          address = zone.updatesFrom;
          key = zone.updateKeyName;
          action = [
            "update"
            "transfer"
          ];
          # external-dns writes these; it never needs to touch SOA/NS.
          update-type = [
            "A"
            "AAAA"
            "CNAME"
            "TXT"
          ];
        };
        template.default = {
          storage = "/var/lib/knot";
          zonefile-sync = -1;
          zonefile-load = "difference-no-serial";
          journal-content = "all";
        };
        zone.${zone.name} = {
          file = pkgs.writeText "${zone.name}.zone" ''
            $ORIGIN ${zone.name}.
            $TTL 300
            @ SOA ns.${zone.name}. hostmaster.${zone.name}. 1 3600 600 86400 300
            @ NS ns.${zone.name}.
            ns A ${cfg.lan.address}
          '';
          acl = [ "updaters" ];
        };
      };
    };

    # Lets discovery (Chromecast/AirPlay/printers) work across zones that opt in.
    services.avahi = lib.mkIf (mdnsIfs != [ ]) {
      enable = true;
      reflector = true;
      allowInterfaces = mdnsIfs;
      publish.enable = false;
      openFirewall = false;
    };

    services.prometheus.exporters.kea = {
      enable = true;
      targets = [ "/run/kea/dhcp4.sock" ];
    };
  };
}
