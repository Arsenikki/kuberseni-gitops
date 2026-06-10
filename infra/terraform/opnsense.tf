# OPNSense network configuration
# Provider: browningluke/opnsense v0.22
# Credentials: opnsense_api_key + opnsense_api_secret in secrets.tfvars (sops-encrypted)
#
# After applying this file, complete the Kea migration in OPNSense UI:
#   Services → Kea DHCP → Enable, then
#   Services → ISC DHCP → Disable

# ── Kea DHCP — LAN subnet ─────────────────────────────────────────────────────
# DHCP range: 192.168.1.100–199 (static reservations below are outside this range)

resource "opnsense_kea_dhcpv4_subnet" "lan" {
  subnet      = "192.168.1.0/24"
  description = "LAN"

  pools = ["192.168.1.100-192.168.1.199"]

  routers     = ["192.168.1.1"]
  dns_servers = ["1.1.1.1", "8.8.8.8"]
}

# ── DHCP Reservations ─────────────────────────────────────────────────────────

# Kubernetes cluster nodes
resource "opnsense_kea_dhcpv4_reservation" "control_plane_01" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "bc:24:11:75:55:eb"
  ip_address  = "192.168.1.41"
  hostname    = "control-plane-01"
  description = "Talos CP-01 (router/minipc)"
}

resource "opnsense_kea_dhcpv4_reservation" "control_plane_02" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "bc:24:11:e5:85:2f"
  ip_address  = "192.168.1.42"
  hostname    = "control-plane-02"
  description = "Talos CP-02 (minipc)"
}

resource "opnsense_kea_dhcpv4_reservation" "control_plane_03" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "bc:24:11:70:e7:4e"
  ip_address  = "192.168.1.43"
  hostname    = "control-plane-03"
  description = "Talos CP-03 (nas)"
}

resource "opnsense_kea_dhcpv4_reservation" "worker_01" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "bc:24:11:0f:1d:1d"
  ip_address  = "192.168.1.44"
  hostname    = "worker-01"
  description = "Talos worker-01 (minipc, Intel Arc GPU)"
}

resource "opnsense_kea_dhcpv4_reservation" "worker_02" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "bc:24:11:ee:72:f2"
  ip_address  = "192.168.1.45"
  hostname    = "worker-02"
  description = "Talos worker-02 (nas)"
}

resource "opnsense_kea_dhcpv4_reservation" "truenas_scale" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "bc:24:11:5c:a1:e0"
  ip_address  = "192.168.1.3"
  hostname    = "truenas-scale"
  description = "TrueNAS Scale (temp, pre-cutover from Core at .2)"
}

# Personal/home devices
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

# ── DNS overrides (add as needed) ─────────────────────────────────────────────
# Example:
# resource "opnsense_unbound_host_override" "truenas_core" {
#   host        = "nas"
#   domain      = "home.arsenikki.casa"
#   server      = "192.168.1.2"
#   description = "TrueNAS Core"
# }
