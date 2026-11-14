# OPNSense network configuration
# Provider: browningluke/opnsense v0.22
# Credentials: opnsense_api_key + opnsense_api_secret in secrets.tfvars (sops-encrypted)

# ── Kea DHCP — LAN subnet ─────────────────────────────────────────────────────

resource "opnsense_kea_dhcpv4_subnet" "lan" {
  subnet      = "192.168.1.0/24"
  description = "LAN"

  pools       = ["192.168.1.100-192.168.1.199"]
  routers     = ["192.168.1.1"]
  dns_servers = ["1.1.1.1", "8.8.8.8"]

  # Pin to OPNSense's actual value — the provider defaults this to true but the
  # write doesn't round-trip, causing a perpetual diff. false matches reality.
  match_client_id = false

  # Keep the DNS servers above. With auto-collect on (the provider default), any save of
  # the Kea model — GUI or the restapi_object below — replaces them with the router's own
  # IP (it flipped DHCP DNS + NTP to 192.168.1.1 on 2026-11-07).
  auto_collect = false
}

# ── Kea DHCP — global lease lifetime ─────────────────────────────────────────
# Not exposed by the opnsense provider, so it's set via its REST API directly.
# Kea's default lease is 4000s, and clients renew at 50% of it (~33 min). Android
# schedules that renewal as a wakeup alarm, which pulled the Formovie projector
# out of standby every ~33 min (fans spin, and its HDMI-CEC wake switches the
# Q990H soundbar input). See Arsenikki/codex android-tv/README.md.
# A 7-day lease means a renewal (and wake) only every ~3.5 days.

locals {
  kea_valid_lifetime = 604800 # 7 days
}

resource "restapi_object" "kea_dhcpv4_general" {
  provider = restapi.opnsense

  # A singleton settings object, not a collection: pin the id and point every
  # operation at the fixed get/set endpoints.
  path         = "/kea/dhcpv4"
  object_id    = "general"
  create_path  = "/kea/dhcpv4/set"
  read_path    = "/kea/dhcpv4/get"
  update_path  = "/kea/dhcpv4/set"
  destroy_path = "/kea/dhcpv4/set"

  # OPNSense returns integer fields as strings, so send one too or the read-back
  # never matches and every plan shows drift.
  data = jsonencode({ dhcpv4 = { general = { valid_lifetime = tostring(local.kea_valid_lifetime) } } })

  # Removing this resource saves Kea's default back (reconfigure Kea by hand after).
  destroy_data = jsonencode({ dhcpv4 = { general = { valid_lifetime = "4000" } } })

  # `get` returns the whole Kea model; only compare the keys set in `data`.
  ignore_server_additions = true

  # `set` saves the whole Kea model from a snapshot, so a reservation or subnet written in
  # parallel gets lost (the projector reservation was, on the first apply). Write after them.
  depends_on = [
    opnsense_kea_dhcpv4_subnet.lan,
    opnsense_kea_dhcpv4_reservation.controlplane,
    opnsense_kea_dhcpv4_reservation.worker,
    opnsense_kea_dhcpv4_reservation.truenas_scale,
    opnsense_kea_dhcpv4_reservation.desktop_main,
    opnsense_kea_dhcpv4_reservation.netgear_ap,
    opnsense_kea_dhcpv4_reservation.laptop,
    opnsense_kea_dhcpv4_reservation.desktop_secondary,
    opnsense_kea_dhcpv4_reservation.vm_hub,
    opnsense_kea_dhcpv4_reservation.bazzite_chromebook,
    opnsense_kea_dhcpv4_reservation.philips_purifier,
    opnsense_kea_dhcpv4_reservation.formovie_projector,
  ]
}

# `set` only saves config.xml; Kea needs a reconfigure to render and load it.
resource "terraform_data" "kea_dhcpv4_reconfigure" {
  triggers_replace = restapi_object.kea_dhcpv4_general.data

  provisioner "local-exec" {
    command = "curl -fsS -k -u \"$OPNSENSE_API_KEY:$OPNSENSE_API_SECRET\" -X POST -H 'Content-Type: application/json' -d '{}' https://192.168.1.1/api/kea/service/reconfigure"
    environment = {
      OPNSENSE_API_KEY    = var.opnsense_api_key
      OPNSENSE_API_SECRET = var.opnsense_api_secret
    }
  }
}

# ── Cluster VM reservations — derived from vms.tf locals ──────────────────────
# MAC, IP and hostname come from the same place as the VM config.
# Adding/removing a VM automatically adds/removes its DHCP reservation.

resource "opnsense_kea_dhcpv4_reservation" "controlplane" {
  for_each = local.controlplane_vms

  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = lower(each.value.mac)
  ip_address  = each.value.ip
  hostname    = each.key
  description = "Talos ${each.key} (${each.value.proxmox_node})"
}

resource "opnsense_kea_dhcpv4_reservation" "worker" {
  for_each = local.worker_vms

  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = lower(each.value.mac)
  ip_address  = each.value.ip
  hostname    = each.key
  description = "Talos ${each.key} (${each.value.proxmox_node})"
}

# TrueNAS Scale — primary NAS at .2 (took over from Core 2026-06-14).
# Note: Scale is configured with a STATIC 192.168.1.2 inside TrueNAS, so it does not
# actually DHCP. This reservation reserves .2 for its MAC as documentation / to keep
# anything else from being handed the address.
resource "opnsense_kea_dhcpv4_reservation" "truenas_scale" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = lower(proxmox_virtual_environment_vm.truenas_scale.network_device[0].mac_address)
  ip_address  = "192.168.1.2"
  hostname    = "truenas-scale"
  description = "TrueNAS Scale (primary NAS, static .2)"
}

# ── Personal/home devices ──────────────────────────────────────────────────────

resource "opnsense_kea_dhcpv4_reservation" "desktop_main" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "2c:f0:5d:7c:93:6c"
  ip_address  = "192.168.1.100"
  hostname    = "DESKTOP-Q0E7TOC"
  description = "Windows Desktop"
}

resource "opnsense_kea_dhcpv4_reservation" "netgear_ap" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "94:18:65:41:1e:05"
  ip_address  = "192.168.1.110"
  hostname    = "NETGEAR411E05"
  description = "Netgear WAX220 Access Point"
}

resource "opnsense_kea_dhcpv4_reservation" "laptop" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "6c:7e:67:c8:b5:a5"
  ip_address  = "192.168.1.111"
  hostname    = "AutLaptopALMBP2"
  description = "Laptop"
}

resource "opnsense_kea_dhcpv4_reservation" "desktop_secondary" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "bc:24:11:02:18:80"
  ip_address  = "192.168.1.124"
  hostname    = "DESKTOP-L9VHPP0"
  description = ""
}

resource "opnsense_kea_dhcpv4_reservation" "vm_hub" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "bc:24:11:7c:51:a9"
  ip_address  = "192.168.1.125"
  hostname    = "arseni-vm-hub"
  description = ""
}

resource "opnsense_kea_dhcpv4_reservation" "bazzite_chromebook" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "ca:e0:0e:6c:cf:c1"
  ip_address  = "192.168.1.105"
  hostname    = "bazzite-chromebook"
  description = "ASUS Chromebook Plus 14 (CX3402CVA/marasov) dual-booted into Bazzite HTPC — see Arsenikki/codex bazzite-chromebook-cx3402cva/"
}

# Raspberry Pi 4 in the bedroom: NixOS, gitops-managed from Arsenikki/nixos-homelab
# (Music Assistant "Bedroom" Sendspin player). Wired MAC (end0); trusted static block.
resource "opnsense_kea_dhcpv4_reservation" "bedroom_pi" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "dc:a6:32:a9:a8:ff"
  ip_address  = "192.168.1.50"
  hostname    = "bedroom-pi"
  description = "Raspberry Pi 4, NixOS (Arsenikki/nixos-homelab)"
}

# ── IoT / home-automation devices ──────────────────────────────────────────────
# Addressing scheme (flat 192.168.1.0/24 today; blocks chosen to map cleanly onto
# future VLANs — keep the last octet when a block migrates to its own subnet):
#   .1            gateway (OPNSense)
#   .2-.9         storage / network infra   ─┐
#   .10-.19       Proxmox hosts              ├─ MGMT  (VLAN 1,  192.168.1.0/24)
#   .40-.49       k8s nodes + API VIP        │
#   .220-.229     k8s LoadBalancer (Cilium) ─┘
#   .50-.99       trusted static  ─┐
#   .100-.149     trusted dynamic  ┴─ TRUSTED (→ VLAN 10, 192.168.10.0/24)
#   .150-.179     IoT static     ─┐
#   .180-.199     IoT dynamic     ┴─ IoT     (→ VLAN 20, 192.168.20.0/24)
# When IoT moves to its own VLAN: HA (k8s/MGMT) → IoT needs a firewall allow rule
# (e.g. udp/5683 CoAP to the purifier); enable an mDNS reflector for autodiscovery.

resource "opnsense_kea_dhcpv4_reservation" "philips_purifier" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "88:a6:8d:16:6e:ba"
  ip_address  = "192.168.1.150"
  hostname    = "philips-purifier"
  description = "Philips 3200 air purifier (MXCHIP wifi; CoAP local control)"
}

# MAC is Android's per-SSID randomized one (stable unless the projector forgets the
# network or is reset), not the device MAC 38:54:39:6c:bc:de.
resource "opnsense_kea_dhcpv4_reservation" "formovie_projector" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.lan.id
  mac_address = "26:78:d3:6e:2d:42"
  ip_address  = "192.168.1.151"
  hostname    = "formovie-projector"
  description = "Formovie Theater Premium projector (Android TV, wifi) — see Arsenikki/codex android-tv/"
}

# ── State migration — rename old individual resources to for_each ──────────────

moved {
  from = opnsense_kea_dhcpv4_reservation.control_plane_01
  to   = opnsense_kea_dhcpv4_reservation.controlplane["control-plane-01"]
}
moved {
  from = opnsense_kea_dhcpv4_reservation.control_plane_02
  to   = opnsense_kea_dhcpv4_reservation.controlplane["control-plane-02"]
}
moved {
  from = opnsense_kea_dhcpv4_reservation.control_plane_03
  to   = opnsense_kea_dhcpv4_reservation.controlplane["control-plane-03"]
}
moved {
  from = opnsense_kea_dhcpv4_reservation.worker_01
  to   = opnsense_kea_dhcpv4_reservation.worker["worker-01"]
}
moved {
  from = opnsense_kea_dhcpv4_reservation.worker_02
  to   = opnsense_kea_dhcpv4_reservation.worker["worker-02"]
}

# ── DNS ───────────────────────────────────────────────────────────────────────
# DNS for both cluster apps and bare-metal infra hosts (proxmox/opnsense/truenas)
# is managed in Cloudflare via external-dns, not OPNSense Unbound.
# See cluster/apps/external-dns/infra-hosts.yaml
