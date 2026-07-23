# TrueNAS SCALE VM — primary NAS (migrated from CORE on 2026-06-14).
#
# Serves the 16TB ZFS pool "main" over NFS at 192.168.1.2 (static, set inside
# TrueNAS — see network note below). The k8s media stack mounts the export
# /mnt/main/nfs/vols/pvc-000f1e6c-... (see cluster/apps/media/plex/media-pvc.yaml).
#
# How the pool got here (Option B — pool import, data never copied):
#   - CORE (old VM 200) exported pool "main"; the single 16TB passthrough disk was
#     detached from VM 200 and attached to this VM as scsi1 (see lifecycle note below).
#   - SCALE imported the pool, recreated the one NFS share, and took over IP .2.
#   - CORE (VM 200) is kept stopped as a rollback option until decommissioned.
#   - 2026-07-03: added a second identical 16TB disk (scsi2) and extended "main"
#     from a single-disk vdev into a 2-way mirror for redundancy (see lifecycle note).
#
# Network: this VM uses a STATIC 192.168.1.2 configured inside TrueNAS (not DHCP),
# so the k8s media-pv (hardcoded server 192.168.1.2) needs no change. The OPNSense
# reservation below reserves .2 for this MAC as documentation / address protection.
#
# Fresh recreate: boots the installer ISO (disk-first boot falls through to ISO on an
# empty disk); install SCALE interactively to scsi0, then re-add the data disk and
# re-import the pool per the steps above.

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
  vm_id           = 202
  stop_on_destroy = true
  started         = true   # Production NAS — keep running
  on_boot         = true   # Auto-start with the Proxmox host (storage must come up on boot)
  bios            = "seabios"
  machine         = "q35"  # PCIe bus required for HDD passthrough; SeaBIOS avoids OVMF/passthrough boot issues
  scsi_hardware   = "virtio-scsi-single"  # One I/O thread per disk via iothread=true
  tags            = ["critical"]          # ProxmoxVMDown alerts only on `critical`-tagged VMs

  agent {
    enabled = true
  }

  cpu {
    cores = 4
    type  = "host"  # Exposes AES-NI to ZFS; avoids SMB CPU spikes with kvm64
  }

  memory {
    dedicated = 16384
  }

  # Boot disk — stores SCALE OS only, not data
  # virtio-scsi-single + iothread gives each disk its own I/O thread (~40% faster than shared controller)
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 32
    file_format  = "raw"
    discard      = "on"
    iothread     = true
  }

  cdrom {
    interface = "ide2"
    file_id   = proxmox_virtual_environment_download_file.truenas_scale_iso.id
  }

  # Disk first — once TrueNAS is installed, it boots from disk regardless of ISO presence
  boot_order = ["scsi0", "ide2"]

  network_device {
    bridge      = "vmbr0"
    mac_address = "BC:24:11:5C:A1:E0"  # fixed MAC — reserve 192.168.1.3 in OPNSense
  }

  operating_system {
    type = "l26"
  }

  # The ZFS data pool ("main") lives on raw-passthrough disks attached out-of-band.
  # The disks physically live in the nas host; tofu never copies or manages their data.
  # bpg's disk block only models datastore-backed volumes, so passthrough is done via qm:
  #   scsi1 — original pool disk (imported from TrueNAS-Core VM 200 by pool export/import):
  #     qm set 202 --scsi1 /dev/disk/by-id/ata-ST16000NM000J-2TW103_ZR55Q0MR,discard=on
  #   scsi2 — mirror partner added 2026-07-03 to make "main" a 2-way mirror (redundancy):
  #     qm set 202 --scsi2 /dev/disk/by-id/ata-ST16000NM002H-3KW133_ZYE0KJN1,discard=on
  # Inside TrueNAS the passthrough disks show QEMU serials (drive-scsi1/drive-scsi2), not
  # their physical serials; the scsi2 disk was wiped and attached to the existing vdev via
  # Storage → main → Extend, which resilvers it into the mirror.
  # ignore_changes guarantees a future `terraform apply` can NEVER detach or recreate
  # these disks, which would be catastrophic for ~14TB of unbacked-up data.
  lifecycle {
    ignore_changes = [disk]
  }
}
