# VM Information Outputs
output "vm_info" {
  description = "Complete information about all created VMs"
  value = {
    for k, v in proxmox_virtual_environment_vm.talos_vm : k => {
      id             = v.id
      name           = v.name
      description    = v.description
      node_name      = v.node_name
      vm_id          = v.vm_id
      status         = v.status
      tags           = v.tags
      cpu_cores      = v.cpu[0].cores
      memory_mb      = v.memory[0].dedicated
      disk_size      = v.disk[0].size
      ipv4_addresses = v.ipv4_addresses
      ipv6_addresses = v.ipv6_addresses
      mac_addresses  = v.mac_addresses
    }
  }
}

# Node IP Addresses
output "node_ips" {
  description = "List of all node IP addresses"
  value = flatten([
    for vm in proxmox_virtual_environment_vm.talos_vm : [
      for ip_list in vm.ipv4_addresses : [
        for ip in ip_list : ip if ip != "127.0.0.1" && !startswith(ip, "169.254.")
      ]
    ]
  ])
}

# Nodes grouped by type (for Talos cluster configuration)
output "control_plane_ips" {
  description = "IP addresses of control plane nodes"
  value = [
    for vm_key, vm in proxmox_virtual_environment_vm.talos_vm : [
      for ip_list in vm.ipv4_addresses : [
        for ip in ip_list : ip if ip != "127.0.0.1" && !startswith(ip, "169.254.")
      ]
    ][0][0] if startswith(vm_key, "control-plane-")
  ]
}

output "worker_ips" {
  description = "IP addresses of worker nodes"
  value = [
    for vm_key, vm in proxmox_virtual_environment_vm.talos_vm : [
      for ip_list in vm.ipv4_addresses : [
        for ip in ip_list : ip if ip != "127.0.0.1" && !startswith(ip, "169.254.")
      ]
    ][0][0] if startswith(vm_key, "worker-")
  ]
}

# Cluster endpoints for Temporal workflow integration
output "cluster_endpoints" {
  description = "Cluster endpoints for Talos configuration"
  value = {
    control_plane_endpoint = length([
      for vm_key, vm in proxmox_virtual_environment_vm.talos_vm : [
        for ip_list in vm.ipv4_addresses : [
          for ip in ip_list : ip if ip != "127.0.0.1" && !startswith(ip, "169.254.")
        ]
      ][0][0] if startswith(vm_key, "control-plane-")
      ]) > 0 ? [
      for vm_key, vm in proxmox_virtual_environment_vm.talos_vm : [
        for ip_list in vm.ipv4_addresses : [
          for ip in ip_list : ip if ip != "127.0.0.1" && !startswith(ip, "169.254.")
        ]
      ][0][0] if startswith(vm_key, "control-plane-")
    ][0] : null

    all_control_plane_ips = [
      for vm_key, vm in proxmox_virtual_environment_vm.talos_vm : [
        for ip_list in vm.ipv4_addresses : [
          for ip in ip_list : ip if ip != "127.0.0.1" && !startswith(ip, "169.254.")
        ]
      ][0][0] if startswith(vm_key, "control-plane-")
    ]

    all_worker_ips = [
      for vm_key, vm in proxmox_virtual_environment_vm.talos_vm : [
        for ip_list in vm.ipv4_addresses : [
          for ip in ip_list : ip if ip != "127.0.0.1" && !startswith(ip, "169.254.")
        ]
      ][0][0] if startswith(vm_key, "worker-")
    ]
  }
}

# Talos image information
output "talos_image_info" {
  description = "Information about the Talos image"
  value = {
    id       = proxmox_virtual_environment_download_file.talos_image.id
    filename = proxmox_virtual_environment_download_file.talos_image.file_name
    size     = proxmox_virtual_environment_download_file.talos_image.size
    url      = var.talos_image_url
  }
}

# VM IDs for external reference
output "vm_ids" {
  description = "Map of VM names to VM IDs"
  value = {
    for k, v in proxmox_virtual_environment_vm.talos_vm : k => v.vm_id
  }
}

# Summary for easy consumption
output "cluster_summary" {
  description = "Summary of the created Talos cluster"
  value = {
    cluster_name        = var.cluster_name
    total_vms           = length(proxmox_virtual_environment_vm.talos_vm)
    control_plane_count = length([for vm_key in keys(proxmox_virtual_environment_vm.talos_vm) : vm_key if startswith(vm_key, "control-plane-")])
    worker_count        = length([for vm_key in keys(proxmox_virtual_environment_vm.talos_vm) : vm_key if startswith(vm_key, "worker-")])
    node_configs        = var.node_configs
  }
}
