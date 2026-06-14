# OPNSense network configuration
# Provider: browningluke/opnsense v0.22
# Credentials: opnsense_api_key + opnsense_api_secret in secrets.tfvars (sops-encrypted)

# ── Kea DHCP — LAN subnet ─────────────────────────────────────────────────────

resource "opnsense_kea_dhcpv4_subnet" "lan" {
  subnet      = "192.168.1.0/24"
  description = "LAN"

  pools       = ["192.168.1.100-192.168.1.199"]
  routers     = ["192.168.1.1"]
  dns_servers = ["1.1.1.1", "8.8.8.8"]

  # Pin to OPNSense's actual value — the provider defaults this to true but the
  # write doesn't round-trip, causing a perpetual diff. false matches reality.
  match_client_id = false
}

# ── Cluster VM reservations — derived from vms.tf locals ──────────────────────
# MAC, IP and hostname come from the same place as the VM config.
# Adding/removing a VM automatically adds/removes its DHCP reservation.

resource "opnsense_kea_dhcpv4_reservation" "controlplane" {
  for_each = local.controlplane_vms

  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = lower(each.value.mac)
  ip_address  = each.value.ip
  hostname    = each.key
  description = "Talos ${each.key} (${each.value.proxmox_node})"
}

resource "opnsense_kea_dhcpv4_reservation" "worker" {
  for_each = local.worker_vms

  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = lower(each.value.mac)
  ip_address  = each.value.ip
  hostname    = each.key
  description = "Talos ${each.key} (${each.value.proxmox_node})"
}

# TrueNAS Scale — primary NAS at .2 (took over from Core 2026-06-14).
# Note: Scale is configured with a STATIC 192.168.1.2 inside TrueNAS, so it does not
# actually DHCP. This reservation reserves .2 for its MAC as documentation / to keep
# anything else from being handed the address.
resource "opnsense_kea_dhcpv4_reservation" "truenas_scale" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = lower(proxmox_virtual_environment_vm.truenas_scale.network_device[0].mac_address)
  ip_address  = "192.168.1.2"
  hostname    = "truenas-scale"
  description = "TrueNAS Scale (primary NAS, static .2)"
}

# ── Personal/home devices ──────────────────────────────────────────────────────

resource "opnsense_kea_dhcpv4_reservation" "desktop_main" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "2c:f0:5d:7c:93:6c"
  ip_address  = "192.168.1.100"
  hostname    = "DESKTOP-Q0E7TOC"
  description = "Windows Desktop"
}

resource "opnsense_kea_dhcpv4_reservation" "netgear_ap" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "94:18:65:41:1e:05"
  ip_address  = "192.168.1.110"
  hostname    = "NETGEAR411E05"
  description = "Netgear WAX220 Access Point"
}

resource "opnsense_kea_dhcpv4_reservation" "laptop" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "6c:7e:67:c8:b5:a5"
  ip_address  = "192.168.1.111"
  hostname    = "AutLaptopALMBP2"
  description = "Laptop"
}

resource "opnsense_kea_dhcpv4_reservation" "desktop_secondary" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "bc:24:11:02:18:80"
  ip_address  = "192.168.1.124"
  hostname    = "DESKTOP-L9VHPP0"
  description = ""
}

resource "opnsense_kea_dhcpv4_reservation" "vm_hub" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "bc:24:11:7c:51:a9"
  ip_address  = "192.168.1.125"
  hostname    = "arseni-vm-hub"
  description = ""
}

# ── IoT / home-automation devices ──────────────────────────────────────────────
# Addressing scheme (flat 192.168.1.0/24 today; blocks chosen to map cleanly onto
# future VLANs — keep the last octet when a block migrates to its own subnet):
#   .1            gateway (OPNSense)
#   .2-.9         storage / network infra   ─┐
#   .10-.19       Proxmox hosts              ├─ MGMT  (VLAN 1,  192.168.1.0/24)
#   .40-.49       k8s nodes + API VIP        │
#   .220-.229     k8s LoadBalancer (Cilium) ─┘
#   .50-.99       trusted static  ─┐
#   .100-.149     trusted dynamic  ┴─ TRUSTED (→ VLAN 10, 192.168.10.0/24)
#   .150-.179     IoT static     ─┐
#   .180-.199     IoT dynamic     ┴─ IoT     (→ VLAN 20, 192.168.20.0/24)
# When IoT moves to its own VLAN: HA (k8s/MGMT) → IoT needs a firewall allow rule
# (e.g. udp/5683 CoAP to the purifier); enable an mDNS reflector for autodiscovery.

resource "opnsense_kea_dhcpv4_reservation" "philips_purifier" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "88:a6:8d:16:6e:ba"
  ip_address  = "192.168.1.150"
  hostname    = "philips-purifier"
  description = "Philips 3200 air purifier (MXCHIP wifi; CoAP local control)"
}

# ── State migration — rename old individual resources to for_each ──────────────

moved {
  from = opnsense_kea_dhcpv4_reservation.control_plane_01
  to   = opnsense_kea_dhcpv4_reservation.controlplane["control-plane-01"]
}
moved {
  from = opnsense_kea_dhcpv4_reservation.control_plane_02
  to   = opnsense_kea_dhcpv4_reservation.controlplane["control-plane-02"]
}
moved {
  from = opnsense_kea_dhcpv4_reservation.control_plane_03
  to   = opnsense_kea_dhcpv4_reservation.controlplane["control-plane-03"]
}
moved {
  from = opnsense_kea_dhcpv4_reservation.worker_01
  to   = opnsense_kea_dhcpv4_reservation.worker["worker-01"]
}
moved {
  from = opnsense_kea_dhcpv4_reservation.worker_02
  to   = opnsense_kea_dhcpv4_reservation.worker["worker-02"]
}

# ── DNS ───────────────────────────────────────────────────────────────────────
# DNS for both cluster apps and bare-metal infra hosts (proxmox/opnsense/truenas)
# is managed in Cloudflare via external-dns, not OPNSense Unbound.
# See cluster/apps/external-dns/infra-hosts.yaml
