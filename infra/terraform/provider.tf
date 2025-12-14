# https://registry.terraform.io/providers/bpg/proxmox/latest
terraform {
  required_version = ">= 1.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.89.1"
    }
  }
}

provider "proxmox" {
  endpoint  = var.pve_api_url
  api_token = "${var.pve_token_id}=${var.pve_token_secret}"
  insecure  = true
  
  ssh {
    agent                = false
    username             = "root"
    private_key          = file(var.ssh_private_key_path)
  }
}
