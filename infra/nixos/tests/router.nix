# End-to-end router test in four VMs:
#   isp    - "the internet": a PPPoE access concentrator (CHAP) on vlan 1, a web server,
#            a headscale control server (Tailscale stand-in), and 203.0.113.0/24 on vlan 3
#   router - modules/router.nix with PPPoE on eth1 (vlan 1) and the LAN on eth2 (vlan 2)
#   client - a LAN host on DHCP, running a web server that's port-forwarded from the WAN
#   remote - a tailnet device out on the internet (vlan 3), using the router as subnet
#            router and exit node
# Run: nix build .#checks.x86_64-linux.router -L
{ self }:
{ lib, pkgs, ... }:
let
  qemu-common = pkgs.callPackage "${pkgs.path}/nixos/lib/qemu-common.nix" { };
  # TLS for headscale; tailscale clients insist on https.
  tls = pkgs.runCommand "headscale-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj /CN=headscale -addext subjectAltName=DNS:headscale \
      -keyout $out/key.pem -out $out/cert.pem
  '';
  webServer = port: text: {
    wantedBy = [ "multi-user.target" ];
    script = "exec ${pkgs.python3}/bin/python3 -m http.server ${toString port} --directory ${pkgs.writeTextDir "index.html" text}";
  };
in
{
  name = "router";

  nodes = {
    isp = {
      virtualisation.vlans = [
        1
        3
      ];
      networking.firewall.enable = false;
      # Otherwise dhcpcd adds a default route via QEMU's user-mode eth0.
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
      networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
        {
          address = "203.0.113.1";
          prefixLength = 24;
        }
      ];
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

      services.headscale = {
        enable = true;
        port = 8080;
        settings = {
          server_url = "https://headscale";
          prefixes = {
            v4 = "100.64.0.0/10";
            v6 = "fd7a:115c:a1e0::/48";
          };
          dns = {
            base_domain = "tailnet";
            override_local_dns = false;
          };
          derp = {
            urls = [ ];
            server = {
              enabled = true;
              region_id = 999;
              stun_listen_addr = "0.0.0.0:3478";
            };
          };
        };
      };
      services.nginx = {
        enable = true;
        virtualHosts.headscale = {
          onlySSL = true;
          sslCertificate = "${tls}/cert.pem";
          sslCertificateKey = "${tls}/key.pem";
          locations."/" = {
            proxyPass = "http://127.0.0.1:8080";
            proxyWebsockets = true;
          };
        };
      };

      environment.etc = {
        "ppp/pppoe-server-options".text = ''
          plugin pppoe.so
          require-chap
          lcp-echo-interval 10
          lcp-echo-failure 2
          nobsdcomp
          noccp
          novj
        '';
        "ppp/chap-secrets".text = ''
          "testuser" * "testpass" *
        '';
      };
      systemd.services.pppoe-server = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [
          (pkgs.rp-pppoe or pkgs.rpPPPoE)
          pkgs.ppp
        ];
        script = ''
          exec pppoe-server -F -O /etc/ppp/pppoe-server-options -q "$(command -v pppd)" \
            -I eth1 -L 192.0.2.1 -R 192.0.2.2
        '';
      };
      systemd.services.web = webServer 80 "internet";
      environment.systemPackages = [
        pkgs.curl
        pkgs.headscale
        pkgs.jq
        pkgs.netcat
      ];
    };

    router =
      { nodes, ... }:
      {
        imports = [ self.nixosModules.router ];
        virtualisation.vlans = [
          1
          2
        ];
        networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
        networking.interfaces.eth2.ipv4.addresses = lib.mkForce [ ];
        services.openssh.enable = true;
        networking.hosts."192.0.2.1" = [ "headscale" ];
        security.pki.certificateFiles = [ "${tls}/cert.pem" ];

        environment.etc."pppoe-options" = {
          mode = "0400";
          text = ''
            user "testuser"
            password "testpass"
          '';
        };

        homelab.router = {
          enable = true;
          wan = {
            interface = "eth1";
            type = "pppoe";
            pppoe.optionsFile = "/etc/pppoe-options";
          };
          lan = {
            interfaces = [ "eth2" ];
            subnet = "192.168.1.0/24";
            address = "192.168.1.1";
          };
          dhcp = {
            pool = "192.168.1.100 - 192.168.1.199";
            reservations = [
              {
                hostname = "client";
                # The MAC QEMU gives the client's NIC on vlan 2.
                mac = qemu-common.qemuNicMac 2 nodes.client.virtualisation.test.nodeNumber;
                ip = "192.168.1.50";
              }
            ];
          };
          portForwards = [
            {
              proto = "tcp";
              port = 80;
              to = "192.168.1.50";
              toPort = 8080;
              description = "client web server";
            }
          ];
          tailscale = {
            enable = true;
            # Written by the test script once headscale has issued a key.
            authKeyFile = "/run/ts-authkey";
            loginServer = "https://headscale";
          };
        };
        environment.systemPackages = [
          pkgs.jq
          pkgs.netcat
        ];
      };

    client = {
      virtualisation.vlans = [ 2 ];
      networking.firewall.enable = false;
      networking.useDHCP = false;
      networking.interfaces.eth1 = {
        ipv4.addresses = lib.mkForce [ ];
        useDHCP = true;
      };
      systemd.services.web = webServer 8080 "lan";
      environment.systemPackages = [
        pkgs.curl
        pkgs.netcat
      ];
    };

    remote = {
      virtualisation.vlans = [ 3 ];
      networking.firewall.enable = false;
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "203.0.113.2";
          prefixLength = 24;
        }
      ];
      networking.defaultGateway = {
        address = "203.0.113.1";
        interface = "eth1";
      };
      networking.hosts."203.0.113.1" = [ "headscale" ];
      security.pki.certificateFiles = [ "${tls}/cert.pem" ];
      services.tailscale.enable = true;
      environment.systemPackages = [ pkgs.curl ];
    };
  };

  testScript = ''
    start_all()

    with subtest("PPPoE session comes up with CHAP"):
        router.wait_for_unit("pppd-wan.service")
        router.wait_until_succeeds("ip -4 addr show ppp0 | grep -q 'inet 192.0.2.2'", timeout=120)

    with subtest("LAN client gets its reserved address and the router as gateway"):
        client.wait_until_succeeds("ip -4 addr show eth1 | grep -q 'inet 192.168.1.50/24'", timeout=120)
        client.succeed("ip route show default | grep -q 'via 192.168.1.1'")

    with subtest("LAN reaches the internet through NAT"):
        isp.wait_for_open_port(80)
        client.wait_until_succeeds("curl -fsS --max-time 5 http://192.0.2.1/ | grep internet >/dev/null", timeout=60)
        # The ISP only sees the router's WAN address.
        isp.succeed("journalctl -u web | grep -q '192.0.2.2 - -'")

    with subtest("Port forward from WAN reaches the LAN host"):
        client.wait_for_open_port(8080)
        isp.succeed("curl -fsS --max-time 5 http://192.0.2.2/ | grep lan >/dev/null")

    with subtest("WAN can't reach the router or the LAN directly"):
        isp.fail("nc -z -w 3 192.0.2.2 22")
        isp.succeed("ip route add 192.168.1.0/24 dev ppp0")
        isp.fail("curl -fsS --max-time 5 http://192.168.1.50:8080/")
        isp.fail("nc -z -w 3 192.168.1.1 22")
        router.succeed("journalctl -k | grep -q 'nft-drop-input: '")
        router.succeed("journalctl -k | grep -q 'nft-drop-forward: '")

    with subtest("LAN can manage the router and scrape Kea"):
        client.succeed("nc -z -w 3 192.168.1.1 22")
        router.wait_for_open_port(9547)
        client.succeed("curl -fsS --max-time 5 http://192.168.1.1:9547/metrics | grep '^kea_dhcp4' >/dev/null")

    with subtest("Tailscale: router logs in and advertises the LAN and an exit node"):
        isp.wait_for_unit("headscale.service")
        isp.wait_for_open_port(443)
        isp.succeed("headscale users create test")
        user_id = isp.succeed("headscale users list -o json | jq -r '.[] | select(.name == \"test\") | .id'").strip()
        key = isp.succeed(f"headscale preauthkeys create --user {user_id} --reusable -o json | jq -r .key").strip()
        router.succeed(f"echo {key} > /run/ts-authkey && systemctl restart tailscaled-autoconnect.service")
        router.wait_until_succeeds("tailscale status --json | jq -e '.BackendState == \"Running\"'", timeout=120)
        remote.wait_for_unit("tailscaled.service")
        remote.succeed(f"tailscale up --login-server https://headscale --auth-key {key} --accept-routes")
        node_id = isp.wait_until_succeeds(
            "headscale nodes list -o json | jq -er '.[] | select(.given_name == \"router\") | .id'"
        ).strip()
        isp.wait_until_succeeds(
            "headscale nodes list -o json | jq -e '.[] | select(.given_name == \"router\")"
            " | (.available_routes // []) | index(\"192.168.1.0/24\") and index(\"0.0.0.0/0\")'",
            timeout=60,
        )
        isp.succeed(f"headscale nodes approve-routes --identifier {node_id} --routes 192.168.1.0/24,0.0.0.0/0,::/0")

    with subtest("Tailscale: a remote tailnet device reaches the LAN through the router"):
        remote.wait_until_succeeds("curl -fsS --max-time 5 http://192.168.1.50:8080/ | grep lan >/dev/null", timeout=120)
        # Subnet routes are masqueraded: the LAN host sees the router.
        client.succeed("journalctl -u web | grep -q '192.168.1.1 - -'")

    with subtest("Tailscale: the router works as an exit node"):
        router_ts_ip = router.succeed("tailscale ip -4").strip()
        remote.succeed(f"tailscale set --exit-node={router_ts_ip}")
        remote.wait_until_succeeds("curl -sS --max-time 5 -o /dev/null http://192.0.2.1/exit-check", timeout=60)
        # Through the exit node, the internet sees the router's WAN address, not 203.0.113.2.
        isp.succeed("journalctl -u web | grep -q '192.0.2.2 - - .*GET /exit-check'")
  '';
}
