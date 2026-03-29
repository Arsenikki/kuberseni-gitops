# OPNSense Kea DHCP configuration for Talos VMs
#
# IMPORTANT: This configuration requires migrating OPNSense from ISC DHCP to Kea DHCP.
# The browningluke/opnsense Terraform provider only supports Kea DHCP, not ISC DHCP.
#
# Options:
# 1. Migrate OPNSense to Kea DHCP (Services → Kea DHCPv4), then apply this config
# 2. Manually configure DHCP reservations in ISC DHCP (Services → DHCPv4 → [LAN])
# 3. Consider alternative DHCP servers (dnsmasq, etc.)
#
# Until migration, use `tofu output` to get MAC addresses, then manually configure
# DHCP reservations in OPNSense ISC DHCP interface.

# LAN subnet configuration
resource "opnsense_kea_subnet" "lan" {
  subnet      = "192.168.1.0/24"
  description = "LAN subnet for Talos cluster"
}

# DHCP reservations for control plane nodes
resource "opnsense_kea_reservation" "controlplane" {
  for_each = proxmox_virtual_environment_vm.controlplane

  subnet_id = opnsense_kea_subnet.lan.id

  ip_address  = local.controlplane_vms[each.key].ip
  mac_address = each.value.mac_addresses[0]
  description = "Talos ${each.key}"
}

# DHCP reservations for worker nodes
resource "opnsense_kea_reservation" "worker" {
  for_each = proxmox_virtual_environment_vm.worker

  subnet_id = opnsense_kea_subnet.lan.id

  ip_address  = local.worker_vms[each.key].ip
  mac_address = each.value.mac_addresses[0]
  description = "Talos ${each.key}"
}
