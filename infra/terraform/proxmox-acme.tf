# Proxmox ACME (Let's Encrypt) via Cloudflare DNS-01 challenge.
# Each node gets its own cert for its *.proxmox.arsenikki.casa hostname.
# After initial order, Proxmox renews automatically via its built-in cron.
#
# agent=false on all SSH connections bypasses the 1Password SSH agent
# (which intercepts and breaks auth to Proxmox nodes).

locals {
  proxmox_nodes_acme = {
    router = { ip = "192.168.1.10", hostname = "router.proxmox.arsenikki.casa" }
    minipc = { ip = "192.168.1.11", hostname = "minipc.proxmox.arsenikki.casa" }
    nas    = { ip = "192.168.1.12", hostname = "nas.proxmox.arsenikki.casa"    }
  }
}

# Register ACME account and Cloudflare DNS plugin cluster-wide (run on primary node).
resource "null_resource" "proxmox_acme_setup" {
  triggers = {
    cloudflare_token = sha256(var.cloudflare_api_token)
    contact          = var.acme_contact_email
  }

  connection {
    type        = "ssh"
    host        = "192.168.1.10"
    user        = "root"
    private_key = file(pathexpand("~/.ssh/arsenikki"))
    agent       = false
  }

  provisioner "remote-exec" {
    inline = [
      "pvesh create /cluster/acme/account --name default --contact 'mailto:${var.acme_contact_email}' --directory https://acme-v02.api.letsencrypt.org/directory 2>/dev/null || true",
      "pvesh create /cluster/acme/plugins --id cloudflare --type dns --api cf --data 'CF_Token=${var.cloudflare_api_token}' 2>/dev/null || pvesh set /cluster/acme/plugins/cloudflare --data 'CF_Token=${var.cloudflare_api_token}'",
    ]
  }
}

# Order cert on each node (set domain + issue).
resource "null_resource" "proxmox_acme_cert" {
  for_each = local.proxmox_nodes_acme

  triggers = {
    setup_id = null_resource.proxmox_acme_setup.id
    hostname = each.value.hostname
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

  depends_on = [null_resource.proxmox_acme_setup]
}
