# TrueNAS SCALE VM — primary NAS (migrated from CORE on 2026-06-14).
#
# Serves the ZFS pool "main" over NFS at 192.168.1.2 (static, set inside
# TrueNAS — see network note below). The pool is now a 2× 16TB mirror
# (~14.5 TiB usable). The k8s media stack mounts the export
# /mnt/main/nfs/vols/pvc-000f1e6c-... (see cluster/apps/media/plex/media-pvc.yaml).
#
# How the pool got here (Option B — pool import, data never copied):
#   - CORE (old VM 200) exported pool "main"; the single 16TB passthrough disk was
#     detached from VM 200 and attached to this VM as scsi1 (see lifecycle note below).
#   - SCALE imported the pool, recreated the one NFS share, and took over IP .2.
#   - CORE (VM 200) is kept stopped as a rollback option until decommissioned.
#   - A second 16TB disk was subsequently added to pool "main" to form a mirror
#     (single mirror-0 vdev across both 16TB disks).
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
  started         = true # Production NAS — keep running
  on_boot         = true # Auto-start with the Proxmox host (storage must come up on boot)
  bios            = "seabios"
  machine         = "q35"                # PCIe bus required for HDD passthrough; SeaBIOS avoids OVMF/passthrough boot issues
  scsi_hardware   = "virtio-scsi-single" # One I/O thread per disk via iothread=true
  tags            = ["critical"]         # ProxmoxVMDown alerts only on `critical`-tagged VMs

  agent {
    enabled = true
  }

  # 4 cores, default cpuunits (was 2 cores + units 50 on the 4-core N5105 nas).
  # nas is a Ryzen 7 5800U (8C/16T) since 2026-11-20 — ZFS scrub/checksums and NFS
  # get real cores without starving cp-03 or worker-02.
  cpu {
    cores = 4
    type  = "host" # Exposes AES-NI to ZFS; avoids SMB CPU spikes with kvm64
    units = 100
  }

  # 8192 (was 12288, was 16384): the 31 GiB nas host was RAM-overcommitted
  # (12 + worker-02 14 + cp-03 6 = 32 GiB) — ~0.7 GiB free, 2 GiB swapped, ksmd
  # burning ~25% of a core. 8 GiB (TrueNAS SCALE minimum) leaves ~11 GiB free.
  # Applied live 2026-10-31; this keeps an apply from re-inflating it.
  memory {
    dedicated = 8192
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
    mac_address = "BC:24:11:5C:A1:E0" # fixed MAC — reserve 192.168.1.3 in OPNSense
  }

  operating_system {
    type = "l26"
  }

  # The ZFS data pool "main" (2x 16TB mirror) lives on disks attached to the onboard
  # ASMedia ASM1166 SATA controller, which is passed through whole (since 2026-11-20,
  # was per-disk scsi1/scsi2 by-id passthrough). TrueNAS owns the controller, so SMART,
  # hotplug and disk errors are native, and the host never sees the pool.
  # Host prerequisites (not managed here — see codex runbook "nas" section):
  #   - /etc/modprobe.d/vfio.conf binds 1b21:1166 to vfio-pci (softdep ahci pre: vfio-pci)
  #   - DKMS module asm1166_nobusreset sets PCI_DEV_FLAGS_NO_BUS_RESET on the ASM1166.
  #     Without it QEMU's bus hot-reset at VM start wedges the chip ("not ready 65535ms
  #     after bus reset", reads 0xffff until host reboot). Upstream quirk exists for
  #     ASM1164 (v6.20) but not ASM1166 yet.
  #   - zfs-import-scan/-cache masked on the host so it never imports "main".
  hostpci {
    device  = "hostpci0"
    mapping = proxmox_virtual_environment_hardware_mapping_pci.nas_asm1166.name
    pcie    = true
    rombar  = true
  }

  # ignore_changes = [disk]: the scsi0 boot disk was created by this resource, but
  # disks were historically attached out-of-band (by-id data disks). Keep a future
  # apply from ever detaching or recreating a disk.
  lifecycle {
    ignore_changes = [disk]
  }
}

# PCI resource mapping for the onboard ASMedia ASM1166 6-port SATA controller on nas
# (Topton Ryzen 7 5800U board), passed through whole to TrueNAS (VM 202).
resource "proxmox_virtual_environment_hardware_mapping_pci" "nas_asm1166" {
  name    = "nas-asm1166"
  comment = "ASMedia ASM1166 SATA (nas onboard) for TrueNAS pool main"
  map = [
    {
      id           = "1b21:1166"
      node         = "nas"
      path         = "0000:04:00.0"
      iommu_group  = 14
      subsystem_id = "1b21:2116"
    }
  ]
}
