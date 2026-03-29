output "controlplane_ips" {
  description = "IP addresses of control plane VMs"
  value       = { for k, v in local.controlplane_vms : k => v.ip }
}

output "worker_ips" {
  description = "IP addresses of worker VMs"
  value       = { for k, v in local.worker_vms : k => v.ip }
}

output "controlplane_macs" {
  description = "MAC addresses of control plane VMs for OPNSense DHCP reservations"
  value       = { for k, v in proxmox_virtual_environment_vm.controlplane : k => v.mac_addresses[0] }
}

output "worker_macs" {
  description = "MAC addresses of worker VMs for OPNSense DHCP reservations"
  value       = { for k, v in proxmox_virtual_environment_vm.worker : k => v.mac_addresses[0] }
}
