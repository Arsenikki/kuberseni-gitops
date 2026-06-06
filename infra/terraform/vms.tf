locals {
  controlplane_vms = {
    control-plane-01 = { proxmox_node = "router",  network_bridge = "vmbr2", vm_id = 1001, cores = 2,  memory = 6144,  disk_size = 50,  ip = "192.168.1.41" }
    control-plane-02 = { proxmox_node = "minipc",  network_bridge = "vmbr0", vm_id = 1002, cores = 2,  memory = 6144,  disk_size = 50,  ip = "192.168.1.42" }
    control-plane-03 = { proxmox_node = "nas",     network_bridge = "vmbr0", vm_id = 1003, cores = 2,  memory = 6144,  disk_size = 50,  ip = "192.168.1.43" }
  }

  worker_vms = {
    # extra_disk_size: additional disk for Longhorn storage (0 = use main disk only)
    worker-01 = { proxmox_node = "minipc", network_bridge = "vmbr0", vm_id = 2001, cores = 10, memory = 20480, disk_size = 50, extra_disk_size = 500, ip = "192.168.1.44" }
    # worker-02: HDD passthrough disks (16TB + 10TB) added manually in Proxmox after VM creation
    worker-02 = { proxmox_node = "nas",    network_bridge = "vmbr0", vm_id = 2002, cores = 3,  memory = 24576, disk_size = 50, extra_disk_size = 0,   ip = "192.168.1.45" }
  }

  all_vms       = merge(local.controlplane_vms, local.worker_vms)
  proxmox_nodes = toset([for v in local.all_vms : v.proxmox_node])
}

# Download Talos metal ISO with iscsi-tools schematic to each Proxmox node.
# VMs boot from this ISO into maintenance mode; Talos installs to the blank disk
# with proper A/B metal layout. After install talosctl upgrade works correctly.
# Schematic 53513e54bb: qemu-guest-agent + iscsi-tools + util-linux-tools
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  for_each = local.proxmox_nodes

  content_type = "iso"
  datastore_id = var.iso_datastore
  node_name    = each.key
  url          = "https://factory.talos.dev/image/53513e54bb39202f35694412577a6bc53d484744d35a126e5d42ef34785c0d83/${var.talos_version}/metal-amd64.iso"
  file_name    = "talos-${var.talos_version}-metal-iscsi.iso"
  overwrite    = false
}

resource "proxmox_virtual_environment_vm" "controlplane" {
  for_each = local.controlplane_vms

  name            = each.key
  node_name       = each.value.proxmox_node
  vm_id           = each.value.vm_id
  stop_on_destroy = true

  agent {
    enabled = true
  }

  efi_disk {
    datastore_id = var.vm_datastore
    file_format  = "raw"
    type         = "4m"
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  # Boot from ISO first (maintenance mode install), then from disk on subsequent boots
  boot_order = ["ide2", "scsi0"]

  # Blank disk — Talos installer writes here during initial boot
  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
    discard      = "on"
  }

  # Talos metal ISO — detach after initial install by running: terraform apply -var boot_from_disk=true
  cdrom {
    interface = "ide2"
    file_id   = proxmox_virtual_environment_download_file.talos_iso[each.value.proxmox_node].id
  }

  network_device {
    bridge = each.value.network_bridge
  }

  operating_system {
    type = "l26"
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  for_each = local.worker_vms

  name            = each.key
  node_name       = each.value.proxmox_node
  vm_id           = each.value.vm_id
  stop_on_destroy = true

  agent {
    enabled = true
  }

  efi_disk {
    datastore_id = var.vm_datastore
    file_format  = "raw"
    type         = "4m"
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
    for_each = each.value.extra_disk_size > 0 ? [1] : []
    content {
      datastore_id = var.vm_datastore
      interface    = "scsi1"
      size         = each.value.extra_disk_size
      file_format  = "raw"
      discard      = "on"
    }
  }

  cdrom {
    interface = "ide2"
    file_id   = proxmox_virtual_environment_download_file.talos_iso[each.value.proxmox_node].id
  }

  network_device {
    bridge = each.value.network_bridge
  }

  operating_system {
    type = "l26"
  }
}
