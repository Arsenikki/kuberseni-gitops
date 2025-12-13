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
      tags           = [for tag in v.tags : tag]
      cpu_cores      = v.cpu[0].cores
      memory_mb      = v.memory[0].dedicated
      disk_size      = v.disk[0].size
      ipv4_address   = try(
        flatten([
          for ip_list in v.ipv4_addresses : [
            for ip in ip_list : ip if ip != "127.0.0.1" && !startswith(ip, "169.254.")
          ]
        ])[0],
        null
      )
      mac_address    = try(
        compact([for mac in v.mac_addresses : mac if mac != "00:00:00:00:00:00"])[0],
        null
      )
    }
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
