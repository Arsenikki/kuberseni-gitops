locals {
  # Proxmox node names — verify with: pvesh get /nodes
  controlplane_vms = {
    control-plane-01 = { proxmox_node = "router",  network_bridge = "vmbr2", vm_id = 1001, cores = 2, memory = 6144,  disk_size = 50,  ip = "192.168.1.41" }
    control-plane-02 = { proxmox_node = "minipc",  network_bridge = "vmbr0", vm_id = 1002, cores = 2, memory = 6144,  disk_size = 50,  ip = "192.168.1.42" }
    control-plane-03 = { proxmox_node = "nas",     network_bridge = "vmbr0", vm_id = 1003, cores = 2, memory = 6144,  disk_size = 50,  ip = "192.168.1.43" }
  }

  worker_vms = {
    # ceph_disk_size: extra virtual disk for Ceph OSD (0 = none, uses HDD passthrough instead)
    worker-01 = { proxmox_node = "minipc", network_bridge = "vmbr0", vm_id = 2001, cores = 10, memory = 20480, disk_size = 50, ceph_disk_size = 500, ip = "192.168.1.44" }
    # worker-02: HDD passthrough disks (16TB + 10TB) added manually in Proxmox after VM creation
    worker-02 = { proxmox_node = "nas",    network_bridge = "vmbr0", vm_id = 2002, cores = 3,  memory = 24576, disk_size = 50, ceph_disk_size = 0,   ip = "192.168.1.45" }
  }

  all_vms = merge(local.controlplane_vms, local.worker_vms)

  # Unique Proxmox nodes — used to download the ISO once per host
  proxmox_nodes = toset([for v in local.all_vms : v.proxmox_node])
}

# Download the Talos nocloud disk image from Image Factory to each Proxmox node
# The nocloud image supports cloud-init datasource for network config via Proxmox initialization block
# Custom schematic with qemu-guest-agent: ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515
resource "proxmox_virtual_environment_download_file" "talos_image" {
  for_each = local.proxmox_nodes

  content_type            = "iso"
  datastore_id            = var.iso_datastore
  node_name               = each.key
  url                     = "https://factory.talos.dev/image/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515/${var.talos_version}/nocloud-amd64.raw.zst"
  file_name               = "talos-${var.talos_version}-nocloud-amd64.img"
  decompression_algorithm = "zst"
  overwrite               = false
}

resource "proxmox_virtual_environment_vm" "controlplane" {
  for_each = local.controlplane_vms

  name      = each.key
  node_name = each.value.proxmox_node
  vm_id     = each.value.vm_id

  # Enable QEMU guest agent (included in custom schematic)
  agent {
    enabled = true
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

  boot_order = ["ide2", "scsi0"]

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
    discard      = "on"
  }

  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_image[each.value.proxmox_node].id
    interface = "ide2"
  }

  network_device {
    bridge = each.value.network_bridge
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.network_gateway
      }
    }
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

  boot_order = ["ide2", "scsi0"]

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
    discard      = "on"
  }

  dynamic "disk" {
    for_each = each.value.ceph_disk_size > 0 ? [1] : []
    content {
      datastore_id = var.vm_datastore
      interface    = "scsi1"
      size         = each.value.ceph_disk_size
      file_format  = "raw"
      discard      = "on"
    }
  }

  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_image[each.value.proxmox_node].id
    interface = "ide2"
  }

  network_device {
    bridge = each.value.network_bridge
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.network_gateway
      }
    }
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [cdrom]
  }
}
