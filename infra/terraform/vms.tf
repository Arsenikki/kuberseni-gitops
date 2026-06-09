locals {
  controlplane_vms = {
    # mac: fixed MAC address — used for OPNSense static DHCP so nodes get correct IP in maintenance mode
    # usb_zigbee: USB device ID (vendor:product) to pass through, or null for no USB
    # control-plane-01: SONOFF Zigbee 3.0 USB Dongle Plus V2 (1a86:55d4) plugged into router
    # machine_type: "q35" for PCIe (GPU passthrough), "" for default i440fx
    control-plane-01 = { proxmox_node = "router",  network_bridge = "vmbr2", vm_id = 1001, cores = 2,  memory = 6144,  disk_size = 50,  ip = "192.168.1.41", mac = "BC:24:11:75:55:EB", usb_zigbee = "1a86:55d4", machine_type = "q35" }
    control-plane-02 = { proxmox_node = "minipc",  network_bridge = "vmbr0", vm_id = 1002, cores = 2,  memory = 6144,  disk_size = 50,  ip = "192.168.1.42", mac = "BC:24:11:E5:85:2F", usb_zigbee = null,          machine_type = "" }
    control-plane-03 = { proxmox_node = "nas",     network_bridge = "vmbr0", vm_id = 1003, cores = 2,  memory = 6144,  disk_size = 50,  ip = "192.168.1.43", mac = "BC:24:11:70:E7:4E", usb_zigbee = null,          machine_type = "" }
  }

  worker_vms = {
    # extra_disk_size: additional disk for Longhorn storage (0 = use main disk only)
    worker-01 = { proxmox_node = "minipc", network_bridge = "vmbr0", vm_id = 2001, cores = 10, memory = 20480, disk_size = 50, extra_disk_size = 500, ip = "192.168.1.44", mac = "BC:24:11:0F:1D:1D" }
    # worker-02: 100GB Longhorn data disk on local-lvm (NAS has 106GB free)
    worker-02 = { proxmox_node = "nas",    network_bridge = "vmbr0", vm_id = 2002, cores = 3,  memory = 24576, disk_size = 50, extra_disk_size = 100, ip = "192.168.1.45", mac = "BC:24:11:EE:72:F2" }
  }

  all_vms       = merge(local.controlplane_vms, local.worker_vms)
  proxmox_nodes = toset([for v in local.all_vms : v.proxmox_node])
}

# USB resource mapping for Zigbee dongle — allows non-root Terraform user to pass
# through the SONOFF Zigbee 3.0 USB Dongle Plus V2 (1a86:55d4) plugged into nas.
resource "proxmox_virtual_environment_hardware_mapping_usb" "zigbee_dongle" {
  name    = "zigbee-dongle"
  comment = "SONOFF Zigbee 3.0 USB Dongle Plus V2"
  map = [
    {
      id   = "1a86:55d4"
      node = "router"
    }
  ]
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
  bios            = "ovmf"  # UEFI — required per Talos Proxmox guide
  machine         = each.value.machine_type != "" ? each.value.machine_type : null

  agent {
    enabled = true
  }

  efi_disk {
    datastore_id = var.vm_datastore
    file_format  = "raw"
    type         = "4m"
  }

  # Serial console for install debugging (talosctl console / serial terminal)
  serial_device {}

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  # Boot from ISO on first install, from disk on all subsequent boots
  boot_order = var.attach_iso ? ["ide2", "scsi0"] : ["scsi0"]

  # Blank disk — Talos installer writes here during initial boot
  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
    discard      = "on"
    iothread     = true  # dedicated I/O thread per disk (~40% better throughput)
  }

  # ISO only needed for first install — remove with: task terraform:remove-iso
  dynamic "cdrom" {
    for_each = var.attach_iso ? [1] : []
    content {
      interface = "ide2"
      file_id   = proxmox_virtual_environment_download_file.talos_iso[each.value.proxmox_node].id
    }
  }

  network_device {
    bridge      = each.value.network_bridge
    mac_address = each.value.mac
  }

  dynamic "usb" {
    for_each = each.value.usb_zigbee != null ? [each.value.usb_zigbee] : []
    content {
      mapping = proxmox_virtual_environment_hardware_mapping_usb.zigbee_dongle.name
      usb3    = true
    }
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
  bios            = "ovmf"

  agent {
    enabled = true
  }

  efi_disk {
    datastore_id = var.vm_datastore
    file_format  = "raw"
    type         = "4m"
  }

  serial_device {}

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  boot_order = var.attach_iso ? ["ide2", "scsi0"] : ["scsi0"]

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

  dynamic "cdrom" {
    for_each = var.attach_iso ? [1] : []
    content {
      interface = "ide2"
      file_id   = proxmox_virtual_environment_download_file.talos_iso[each.value.proxmox_node].id
    }
  }

  network_device {
    bridge      = each.value.network_bridge
    mac_address = each.value.mac
  }

  operating_system {
    type = "l26"
  }
}
