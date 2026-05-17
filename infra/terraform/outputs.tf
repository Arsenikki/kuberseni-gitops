output "controlplane_ips" {
  description = "IP addresses of control plane VMs"
  value       = { for k, v in local.controlplane_vms : k => v.ip }
}

output "worker_ips" {
  description = "IP addresses of worker VMs"
  value       = { for k, v in local.worker_vms : k => v.ip }
}
