# End-to-end router test in three VMs:
#   isp    - a PPPoE access concentrator (CHAP) plus a web server: "the internet"
#   router - modules/router.nix with PPPoE on eth1 (vlan 1) and the LAN on eth2 (vlan 2)
#   client - a LAN host on DHCP, running a web server that's port-forwarded from the WAN
# Run: nix build .#checks.x86_64-linux.router -L
{ self }:
{ lib, pkgs, ... }:
let
  qemu-common = pkgs.callPackage "${pkgs.path}/nixos/lib/qemu-common.nix" { };
  webServer = port: text: {
    wantedBy = [ "multi-user.target" ];
    script = "exec ${pkgs.python3}/bin/python3 -m http.server ${toString port} --directory ${pkgs.writeTextDir "index.html" text}";
  };
in
{
  name = "router";

  nodes = {
    isp = {
      virtualisation.vlans = [ 1 ];
      networking.firewall.enable = false;
      # Otherwise dhcpcd adds a default route via QEMU's user-mode eth0.
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];

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
        };
        environment.systemPackages = [ pkgs.netcat ];
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
        client.wait_until_succeeds("curl -fsS --max-time 5 http://192.0.2.1/ | grep -q internet", timeout=60)
        # The ISP only sees the router's WAN address.
        isp.succeed("journalctl -u web | grep -q '192.0.2.2 - -'")

    with subtest("Port forward from WAN reaches the LAN host"):
        client.wait_for_open_port(8080)
        isp.succeed("curl -fsS --max-time 5 http://192.0.2.2/ | grep -q lan")

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
        client.succeed("curl -fsS --max-time 5 http://192.168.1.1:9547/metrics | grep -q '^kea_dhcp4'")
  '';
}
