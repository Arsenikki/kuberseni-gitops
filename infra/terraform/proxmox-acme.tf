# Proxmox ACME (Let's Encrypt) via Cloudflare DNS-01 challenge.
# Each node gets its own cert for its *.proxmox.arsenikki.casa hostname.
# After initial order, Proxmox renews automatically via its built-in cron.

resource "proxmox_virtual_environment_acme_account" "default" {
  name      = "default"
  contact   = ["mailto:${var.acme_contact_email}"]
  directory = "https://acme-v02.api.letsencrypt.org/directory"
}

resource "proxmox_virtual_environment_acme_plugin" "cloudflare" {
  plugin = "cloudflare"
  type   = "dns"
  api    = "cf"
  data   = "CF_Token=${var.cloudflare_api_token}"

  depends_on = [proxmox_virtual_environment_acme_account.default]
}

locals {
  proxmox_nodes_acme = {
    router = { ip = "192.168.1.10", hostname = "router.proxmox.arsenikki.casa" }
    minipc = { ip = "192.168.1.11", hostname = "minipc.proxmox.arsenikki.casa" }
    nas    = { ip = "192.168.1.12", hostname = "nas.proxmox.arsenikki.casa"    }
  }
}

# SSH into each node to set the ACME domain and order the cert.
# agent=false bypasses the 1Password SSH agent (which intercepts and breaks Proxmox SSH).
# Triggers re-run if plugin or target hostname changes; Proxmox handles renewals itself.
resource "null_resource" "proxmox_acme_cert" {
  for_each = local.proxmox_nodes_acme

  triggers = {
    plugin_id = proxmox_virtual_environment_acme_plugin.cloudflare.plugin
    hostname  = each.value.hostname
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "root"
    private_key = file(pathexpand("~/.ssh/arsenikki"))
    agent       = false
  }

  provisioner "remote-exec" {
    inline = [
      "pvenode config set --acmedomain0 '${each.value.hostname},plugin=cloudflare'",
      "pvenode acme cert order || pvenode acme cert renew",
    ]
  }

  depends_on = [proxmox_virtual_environment_acme_plugin.cloudflare]
}
