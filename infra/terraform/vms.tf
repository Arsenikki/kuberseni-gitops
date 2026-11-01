locals {
  controlplane_vms = {
    # mac: fixed MAC address — used for OPNSense static DHCP so nodes get correct IP in maintenance mode
    # usb_zigbee: USB device ID (vendor:product) to pass through, or null for no USB
    # control-plane-01: SONOFF Zigbee 3.0 USB Dongle Plus V2 (1a86:55d4) plugged into router
    # machine_type: "q35" for PCIe (GPU passthrough), "" for default i440fx
    # network_bridge vmbr1 = the router host's LAN bridge directly on the physical switch
    # (host mgmt + OPNSense LAN gateway live here). Previously vmbr2, which reached the LAN
    # only THROUGH OPNSense's internal net1<->net2 bridge — fragile, broke cross-node
    # routing and made the API VIP unreachable when it failed over to cp-01.
    control-plane-01 = { proxmox_node = "router",  network_bridge = "vmbr1", vm_id = 1001, cores = 2,  memory = 6144,  disk_size = 50,  ip = "192.168.1.41", mac = "BC:24:11:75:55:EB", usb_zigbee = "1a86:55d4", machine_type = "q35" }
    control-plane-02 = { proxmox_node = "minipc",  network_bridge = "vmbr0", vm_id = 1002, cores = 2,  memory = 6144,  disk_size = 50,  ip = "192.168.1.42", mac = "BC:24:11:E5:85:2F", usb_zigbee = null,          machine_type = "q35" }
    control-plane-03 = { proxmox_node = "nas",     network_bridge = "vmbr0", vm_id = 1003, cores = 2,  memory = 6144,  disk_size = 50,  ip = "192.168.1.43", mac = "BC:24:11:70:E7:4E", usb_zigbee = null,          machine_type = "q35" }
  }

  worker_vms = {
    # extra_disk_size: additional disk for Longhorn storage (0 = use main disk only)
    # gpu_mapping: PCI hardware mapping name for iGPU passthrough (null = no GPU)
    # cores=14: minipc is a 16-thread host running only ~20% busy; worker-01 (14) +
    # control-plane-02 (2) + paseo-homelab (6) overcommits vCPU, but real CPU use is
    # low and this gives k8s enough allocatable CPU to end the scheduling pressure.
    # RAM stays at 20 GiB — minipc memory is ~full, so cores (not RAM) are the lever.
    worker-01 = { proxmox_node = "minipc", network_bridge = "vmbr0", vm_id = 2001, cores = 14, memory = 20480, disk_size = 50, extra_disk_size = 500, ip = "192.168.1.44", mac = "BC:24:11:0F:1D:1D", machine_type = "q35", gpu_mapping = "minipc-igpu" }
    # worker-02: 130GB Longhorn data disk on local-lvm (grown live from 100; Proxmox
    # can't shrink, so the code must never go below the live size). local-lvm is a
    # thin pool that is ~98% full (2026-10-31) — don't grow this further.
    # 14 GiB (was 16, was 24): nas is only 32 GiB and also hosts TrueNAS(12) +
    # cp-03(6); 16(w02)+12(nas)+6(cp03)=34 GiB overcommits the 31 GiB host, which
    # sits with ~1 GiB free and multiple GiB swapped. worker-02 has only ever used
    # ~11.5 GiB, so 14 frees ~2 GiB of real host RAM while leaving comfortable
    # headroom. NOTE: applying this reboots worker-02 (balloon:0 → no hot-resize);
    # do it on a maintenance window AFTER metrics-server + the real-usage
    # descheduler land and worker-02 has rebalanced to a light pod set, so the
    # reboot doesn't repack a heavy load onto the smaller VM.
    worker-02 = { proxmox_node = "nas",    network_bridge = "vmbr0", vm_id = 2002, cores = 3,  memory = 14336, disk_size = 50, extra_disk_size = 130, ip = "192.168.1.45", mac = "BC:24:11:EE:72:F2", machine_type = "q35", gpu_mapping = null }
  }

  # Proxmox cpuunits = relative CPU weight between VMs on the same host (PVE default
  # 100 on cgroup v2). nas is a 4-core Celeron N5105 running 9 vCPUs (TrueNAS 4 +
  # cp-03 2 + worker-02 3), so under contention etcd (cp-03) wins first, then
  # worker-02 (Longhorn engines); TrueNAS is 50 (truenas-scale.tf).
  # Unlisted VMs keep the provider default.
  cpu_units = {
    control-plane-03 = 200
    worker-02        = 150
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

# PCI resource mapping for worker-01's Intel Iris Xe iGPU (full passthrough).
# Host runs with nomodeset, VM owns the GPU.
resource "proxmox_virtual_environment_hardware_mapping_pci" "minipc_igpu" {
  name    = "minipc-igpu"
  comment = "Intel Raptor Lake-P Iris Xe (minipc) for worker-01 / Plex transcoding"
  map = [
    {
      id           = "8086:a7a0"
      node         = "minipc"
      path         = "0000:00:02.0"
      iommu_group  = 0
      subsystem_id = "8086:2212"
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
  scsi_hardware   = "virtio-scsi-single"  # required for iothread per disk
  tags            = ["critical"]          # ProxmoxVMDown alerts only on `critical`-tagged VMs

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
    units = lookup(local.cpu_units, each.key, null)
  }

  memory {
    dedicated = each.value.memory
  }

  # Boot from ISO on first install, from disk on all subsequent boots
  boot_order = ["scsi0", "ide2"]  # disk-first: empty disk falls through to ISO on fresh install, installed disk always boots directly

  # Blank disk — Talos installer writes here during initial boot
  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
    discard      = "on"
    iothread     = true  # dedicated I/O thread per disk (~40% better throughput)
  }

  cdrom {
    interface = "ide2"
    file_id   = proxmox_virtual_environment_download_file.talos_iso[each.value.proxmox_node].id
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
  machine         = each.value.machine_type != "" ? each.value.machine_type : null
  scsi_hardware   = "virtio-scsi-single"
  tags            = ["critical"]  # ProxmoxVMDown alerts only on `critical`-tagged VMs

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
    units = lookup(local.cpu_units, each.key, null)
  }

  memory {
    dedicated = each.value.memory
  }

  boot_order = ["scsi0", "ide2"]  # disk-first: empty disk falls through to ISO on fresh install, installed disk always boots directly

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
    discard      = "on"
    iothread     = true
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
    bridge      = each.value.network_bridge
    mac_address = each.value.mac
  }

  dynamic "hostpci" {
    for_each = each.value.gpu_mapping != null ? [each.value.gpu_mapping] : []
    content {
      device  = "hostpci0"
      mapping = hostpci.value
      pcie    = true
      rombar  = true
    }
  }

  operating_system {
    type = "l26"
  }
}
