# Proxmox Infrastructure for Talos Linux
# This configuration creates VMs on Proxmox using the native bpg/proxmox provider
# https://registry.terraform.io/providers/bpg/proxmox/latest

terraform {
  required_version = ">= 1.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.89.1"
    }
  }
}

provider "proxmox" {
  endpoint  = var.pve_api_url
  api_token = "${var.pve_token_id}=${var.pve_token_secret}"
  insecure  = true
  
  ssh {
    agent                = false
    username             = "root"
    private_key          = file(var.ssh_private_key_path)
  }
}

# Download Talos image if enabled
resource "proxmox_virtual_environment_download_file" "talos_image" {
  datastore_id            = "local"
  node_name               = "minipc"
  content_type            = "iso"
  url                     = var.talos_image_url
}

# Create VMs for each node configuration
resource "proxmox_virtual_environment_vm" "talos_vm" {
  for_each = {
    for pair in flatten([
      for node_type in var.node_configs : [
        for i in range(node_type.count) : {
          key       = "${node_type.name}-${i + 1}"
          node_type = node_type
          index     = i + 1
        }
      ]
    ]) : pair.key => pair
  }

  name        = each.key
  description = "Talos ${each.value.node_type.role} node ${each.value.index}"
  node_name   = var.node_name
  vm_id       = var.vm_id_base + each.value.index + (index(var.node_configs, each.value.node_type) * 100)

  # Start VM on virtualization host boot
  on_boot = true

  # CPU Configuration
  cpu {
    cores = each.value.node_type.cpu_cores
    type  = "x86-64-v2-AES"
  }

  # Memory Configuration
  memory {
    dedicated = each.value.node_type.memory_mb
    floating  = each.value.node_type.memory_mb
  }

  # QEMU guest agent
  agent {
    enabled = true
    trim    = true
  }

  operating_system {
    # Linux Kernel 2.6 - 5.X.
    type = "l26"
  }

  # OS disk
  disk {
    file_id      = proxmox_virtual_environment_download_file.talos_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = each.value.node_type.os_disk_size_gb
    file_format  = "raw"
    replicate    = false
  }

  # Data disk
  disk {
    interface    = "virtio1"
    iothread     = true
    discard      = "on"
    size         = each.value.node_type.data_disk_size_gb
    file_format  = "raw"
    replicate    = false
  }

  # Network
  network_device {
    enabled  = true
    firewall = false
  }
  initialization {
    datastore_id = "local-lvm"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  # VM Options
  machine = "q35,viommu=intel"

  # Tags for organization
  tags = ["talos", each.value.node_type.role]

  # Ensure VMs are created sequentially within each node type
  depends_on = [proxmox_virtual_environment_download_file.talos_image]
}
