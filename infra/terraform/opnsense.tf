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

# TrueNAS Scale — MAC from the VM resource, IP is temporary (.3 pre-cutover)
resource "opnsense_kea_dhcpv4_reservation" "truenas_scale" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = lower(proxmox_virtual_environment_vm.truenas_scale.network_device[0].mac_address)
  ip_address  = "192.168.1.3"
  hostname    = "truenas-scale"
  description = "TrueNAS Scale (temp, pre-cutover from Core at .2)"
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

# ── DNS overrides (add as needed) ─────────────────────────────────────────────
# resource "opnsense_unbound_host_override" "truenas_core" {
#   host        = "nas"
#   domain      = "home.arsenikki.casa"
#   server      = "192.168.1.2"
#   description = "TrueNAS Core"
# }
