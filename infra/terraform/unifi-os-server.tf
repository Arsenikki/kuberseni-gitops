# UniFi OS Server VM: the UniFi controller for the Flex Mini 2.5G switch and the
# U6-Pro AP (VLANs main / IoT / guest; OPNSense stays the router, DHCP and firewall).
#
# Runs ON DEMAND, not 24/7: adopted UniFi devices keep their last pushed config while
# the controller is off. on_boot = false, and the paseo-generic agent's API token may
# start/stop this VM (AgentPower on /vms/110, proxmox-agent.tf). Start it for changes,
# then shut it down. `started` is ignored below so an apply never flips it.
#
# UniFi OS Server is Ubiquiti's supported self-hosting route (a Linux host running its
# Podman stack); there is no official container image, hence a VM. Ubiquiti: don't
# clone this VM. Restore from a .unifi backup instead.
#
# First boot (cloud-init, below) installs podman, then the pinned UniFi OS Server
# installer (sha256-checked). It takes several minutes; follow it with
#   ssh root@192.168.1.11 qm guest exec 110 -- tail -n 20 /var/log/unifi-os-install.log
# then open https://192.168.1.4:11443 to finish setup.
#
# Stays on UOS 5.1.x / Network 10.6.x on purpose: Network 11 needs UniFi OS 6.0 (Early
# Access as of 2026-11) and the IaC/MCP tooling isn't verified on it yet. Turn off
# auto-update in the UOS UI. Bumping uos_installer_* only matters for a fresh install;
# an existing VM updates itself from the UI.

locals {
  unifi_os_server = {
    vm_id  = 110
    node   = "minipc"
    ip     = "192.168.1.4"
    mac    = "BC:24:11:E4:9A:5D"
    cores  = 2
    memory = 3072 # UOS idles ~1.7-1.9 GiB; plus a 2 GiB swapfile from cloud-init
    disk   = 32
  }

  # https://fw-update.ui.com/api/firmware-latest → product unifi-os-server, linux-x64, release channel
  uos_installer_version = "5.1.42"
  uos_installer_url     = "https://fw-download.ubnt.com/data/unifi-os-server/5172-linux-x64-5.1.42-12e9e3cf-8f8b-4e54-928c-76b80a10c8a4.42-x64"
  uos_installer_sha256  = "f6111e9396a42c74016f5dde9b01fbef486a6fe69efe137935e6e38b7c22f94d"

  # Debian 13 (trixie) genericcloud, pinned build (Podman 5.x; UOS needs Podman >= 4.9.3)
  debian13_image_build  = "20261111-2659"
  debian13_image_sha512 = "3247873136ba09b060fab45e9c115239f81c1d401fce00b8fa9b872013f7135d6a40b12462ab5ac03b9fa4ed5955dd0e8d1c900109a939ad7a0a4dafe7dea47b"

  # SSH access to the guest: the owner's key and the paseo-generic agent's key.
  unifi_os_server_ssh_keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC/5+LRMLksIYtgj2GJnbKSi8qzZSaPJkp43KxHOYe6MwCtwB4GRenxNSfSFi/50WJ874225N7DgAtD8SIwXeWWe0Rq4Bn8JdSxjQtCw+qgLSKHoVwb3w2hwbd3VR9E/FWpFYfaZKd72cWDQdAwLInR/q/8llh/MTPeZmcVtINaDASrA4NiqQwr8/lDZGbxqMcLSk1XWtQaia7/7a6sSAvp9dJH3sQqxjCzqHQUH9iuoHkQpbO5X23vPudXSrr+Q5lDdvsLWHTkyWSttXwmcebVg7f44eJ7YLvpcEoemyME/EkqExmvM5mAFB9SY2NlcDDE0d/pGCEVWPrP4B5HAjggz4iCfmDWObRE3PRFKmugamxtRd2YBuyuwkmbp23LnYcMe/8UbGVwmKssGEvuIX60PxpQWoWZelF/qHDaPw2uYoVGEFQ5ciSp6B1b0A2DTuxFUsSU6U7Qs6+BAJXGzWhNYOJfhPG0K2llVBebfBUtgMv8n+8xZFCBrEKbKS39EIs= arsenikki",
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB+pln2J9FmCVKkhts28Y+cWuQeAw0YnVxtZyw2xRs1r paseo",
  ]
}

resource "proxmox_virtual_environment_download_file" "debian13_cloud" {
  node_name          = local.unifi_os_server.node
  content_type       = "iso" # PVE 8.2 on minipc has no "import" content type; .img in iso works for disk import
  datastore_id       = var.iso_datastore
  url                = "https://cloud.debian.org/images/cloud/trixie/${local.debian13_image_build}/debian-13-genericcloud-amd64-${local.debian13_image_build}.qcow2"
  file_name          = "debian-13-genericcloud-amd64-${local.debian13_image_build}.img"
  checksum           = local.debian13_image_sha512
  checksum_algorithm = "sha512"
  overwrite          = false
}

resource "proxmox_virtual_environment_file" "unifi_os_server_cloud_init" {
  node_name    = local.unifi_os_server.node
  content_type = "snippets"
  datastore_id = "local"

  source_raw {
    file_name = "unifi-os-server-user-data.yaml"
    data      = <<-EOT
      #cloud-config
      hostname: unifi-os-server
      manage_etc_hosts: true
      timezone: Europe/London

      users:
        - name: root
          ssh_authorized_keys: ${jsonencode(local.unifi_os_server_ssh_keys)}
      disable_root: false
      ssh_pwauth: false

      package_update: true
      packages: [qemu-guest-agent, podman, uidmap, slirp4netns, curl, ca-certificates]

      swap:
        filename: /swapfile
        size: 2G

      write_files:
        - path: /usr/local/sbin/install-unifi-os-server
          permissions: "0755"
          content: |
            #!/bin/bash
            set -euo pipefail
            exec >>/var/log/unifi-os-install.log 2>&1
            echo "[$(date)] downloading UniFi OS Server ${local.uos_installer_version}"
            curl -fsSL --retry 5 -o /opt/unifi-os-server.bin '${local.uos_installer_url}'
            echo '${local.uos_installer_sha256}  /opt/unifi-os-server.bin' | sha256sum -c -
            chmod +x /opt/unifi-os-server.bin
            cd /opt && ./unifi-os-server.bin <<<'y'
            rm -f /opt/unifi-os-server.bin
            echo "[$(date)] UniFi OS Server installed; UI on https://${local.unifi_os_server.ip}:11443"

      runcmd:
        - systemctl enable --now qemu-guest-agent
        - /usr/local/sbin/install-unifi-os-server
    EOT
  }
}

resource "proxmox_virtual_environment_vm" "unifi_os_server" {
  name            = "unifi-os-server"
  description     = "UniFi OS Server (on-demand controller). Managed by kuberseni-gitops infra/terraform/unifi-os-server.tf"
  node_name       = local.unifi_os_server.node
  vm_id           = local.unifi_os_server.vm_id
  on_boot         = false # on demand: started by hand or by the paseo-generic agent
  started         = true  # start once on create so cloud-init installs UOS; ignored afterwards
  stop_on_destroy = true
  machine         = "q35"
  scsi_hardware   = "virtio-scsi-single"
  tags            = ["unifi", "on-demand"]

  agent {
    enabled = true
  }

  cpu {
    cores = local.unifi_os_server.cores
    type  = "host"
  }

  memory {
    dedicated = local.unifi_os_server.memory
  }

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    file_id      = proxmox_virtual_environment_download_file.debian13_cloud.id
    size         = local.unifi_os_server.disk
    file_format  = "raw"
    discard      = "on"
    iothread     = true
  }

  # Untagged main LAN: UniFi L2 discovery/adoption needs the controller on the same
  # segment as the devices' management (the Flex Mini 2.5G has no SSH for set-inform).
  network_device {
    bridge      = "vmbr0"
    mac_address = local.unifi_os_server.mac
  }

  initialization {
    datastore_id = var.vm_datastore
    ip_config {
      ipv4 {
        address = "dhcp" # fixed by the Kea reservation below
      }
    }
    user_data_file_id = proxmox_virtual_environment_file.unifi_os_server_cloud_init.id
  }

  serial_device {}

  operating_system {
    type = "l26"
  }

  lifecycle {
    # Power state is operated on demand, not by tofu.
    ignore_changes = [started]
  }
}

resource "opnsense_kea_dhcpv4_reservation" "unifi_os_server" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = lower(local.unifi_os_server.mac)
  ip_address  = local.unifi_os_server.ip
  hostname    = "unifi-os-server"
  description = "UniFi OS Server VM 110 (minipc), on-demand UniFi controller"
}
