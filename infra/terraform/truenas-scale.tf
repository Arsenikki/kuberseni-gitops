# TrueNAS SCALE VM — runs alongside TrueNAS CORE during migration.
#
# Migration plan (Option B — pool import):
#   1. Deploy this VM, install SCALE via Proxmox console using the ISO
#   2. Configure SCALE (networking, NFS, shares) at 192.168.1.3
#   3. Validate SCALE works for all consumers (Kubernetes NFS mounts, etc.)
#   4. When ready to cut over:
#      a. Stop write-heavy workloads (qBittorrent, etc.)
#      b. In TrueNAS CORE: export the ZFS pool (Storage → Pool → Export/Disconnect)
#      c. In Proxmox: detach HDD passthrough from CORE VM (set to passthrough=false)
#      d. In Proxmox: attach same HDD to SCALE VM (add scsi device)
#      e. In TrueNAS SCALE: import the ZFS pool (Storage → Import Pool)
#      f. Reassign 192.168.1.2 to SCALE (or update Kubernetes PV)
#      g. Decommission TrueNAS CORE VM

locals {
  truenas_scale_version = "24.10.2"
  truenas_scale_iso_url = "https://download.truenas.com/TrueNAS-SCALE-ElectricEel/24.10.2/TrueNAS-SCALE-24.10.2.iso"
}

resource "proxmox_virtual_environment_download_file" "truenas_scale_iso" {
  node_name    = "nas"
  content_type = "iso"
  datastore_id = "local"
  url          = local.truenas_scale_iso_url
  file_name    = "TrueNAS-SCALE-${local.truenas_scale_version}.iso"
  overwrite    = false
}

resource "proxmox_virtual_environment_vm" "truenas_scale" {
  name            = "TrueNAS-Scale"
  node_name       = "nas"
  vm_id           = 201
  stop_on_destroy = true
  bios            = "seabios"

  agent {
    enabled = false
  }

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 16384
  }

  # Boot disk — stores SCALE OS only, not data
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 32
    file_format  = "raw"
    discard      = "on"
  }

  # ISO for initial installation — remove after install by setting attach_scale_iso = false
  dynamic "cdrom" {
    for_each = var.attach_scale_iso ? [1] : []
    content {
      interface = "ide2"
      file_id   = proxmox_virtual_environment_download_file.truenas_scale_iso.id
    }
  }

  boot_order = var.attach_scale_iso ? ["ide2", "scsi0"] : ["scsi0"]

  network_device {
    bridge      = "vmbr0"
    mac_address = "BC:24:11:AA:BB:CC"
  }

  operating_system {
    type = "l26"
  }
}
