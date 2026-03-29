locals {
  # Proxmox node names — verify with: pvesh get /nodes
  controlplane_vms = {
    control-plane-01 = { proxmox_node = "router",  network_bridge = "vmbr2", vm_id = 1001, cores = 2, memory = 6144,  disk_size = 64,  ip = "192.168.1.41" }
    control-plane-02 = { proxmox_node = "minipc",  network_bridge = "vmbr0", vm_id = 1002, cores = 2, memory = 6144,  disk_size = 64,  ip = "192.168.1.42" }
    control-plane-03 = { proxmox_node = "nas",     network_bridge = "vmbr0", vm_id = 1003, cores = 2, memory = 6144,  disk_size = 64,  ip = "192.168.1.43" }
  }

  worker_vms = {
    worker-01 = { proxmox_node = "minipc", network_bridge = "vmbr0", vm_id = 2001, cores = 10, memory = 20480, disk_size = 512, ip = "192.168.1.44" }
  }

  all_vms = merge(local.controlplane_vms, local.worker_vms)

  # Unique Proxmox nodes — used to download the ISO once per host
  proxmox_nodes = toset([for v in local.all_vms : v.proxmox_node])
}

# Download the Talos ISO to each Proxmox node that hosts a VM
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  for_each = local.proxmox_nodes

  content_type = "iso"
  datastore_id = var.iso_datastore
  node_name    = each.key
  url          = "https://github.com/siderolabs/talos/releases/download/${var.talos_version}/metal-amd64.iso"
  file_name    = "talos-${var.talos_version}-amd64.iso"
}

resource "proxmox_virtual_environment_vm" "controlplane" {
  for_each = local.controlplane_vms

  name      = each.key
  node_name = each.value.proxmox_node
  vm_id     = each.value.vm_id

  # Talos does not use the QEMU guest agent
  agent {
    enabled = false
  }

  # UEFI firmware (efi_disk enables OVMF/UEFI automatically)
  efi_disk {
    datastore_id = var.vm_datastore
    file_format  = "raw"
    type         = "4m"  # 4MB EFI disk for UEFI variables
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  # Boot from disk first; falls back to ISO when disk is empty
  boot_order = ["scsi0", "ide2"]

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
    discard      = "on"
  }

  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_iso[each.value.proxmox_node].id
    interface = "ide2"
  }

  network_device {
    bridge = each.value.network_bridge
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    # Prevent Terraform from re-imaging a running node if the ISO changes
    ignore_changes = [cdrom]
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  for_each = local.worker_vms

  name      = each.key
  node_name = each.value.proxmox_node
  vm_id     = each.value.vm_id

  agent {
    enabled = false
  }

  # UEFI firmware (efi_disk enables OVMF/UEFI automatically)
  efi_disk {
    datastore_id = var.vm_datastore
    file_format  = "raw"
    type         = "4m"  # 4MB EFI disk for UEFI variables
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  boot_order = ["scsi0", "ide2"]

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
    discard      = "on"
  }

  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_iso[each.value.proxmox_node].id
    interface = "ide2"
  }

  network_device {
    bridge = each.value.network_bridge
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [cdrom]
  }
}
