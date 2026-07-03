variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://192.168.1.10:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token in format user@realm!tokenid=secret"
  type        = string
  sensitive   = true
}

variable "talos_version" {
  description = "Talos Linux version to download"
  type        = string
  default     = "v1.13.2"
}

variable "iso_datastore" {
  description = "Proxmox datastore to upload Talos ISO to"
  type        = string
  default     = "local"
}

variable "vm_datastore" {
  description = "Proxmox datastore for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "network_gateway" {
  description = "Default network gateway for VMs"
  type        = string
  default     = "192.168.1.1"
}

variable "opnsense_api_key" {
  description = "OPNSense API key"
  type        = string
  sensitive   = true
}

variable "opnsense_api_secret" {
  description = "OPNSense API secret"
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit for arsenikki.casa (used by Proxmox ACME)"
  type        = string
  sensitive   = true
}

variable "acme_contact_email" {
  description = "Contact email for Let's Encrypt ACME account on Proxmox nodes"
  type        = string
  sensitive   = true
}

variable "proxmox_ssh_private_key_path" {
  description = "Path to the SSH private key the Proxmox provider + ACME provisioners use to reach the PVE nodes as root. Defaults to the maintainer's key; override per-host (e.g. the in-cluster paseo box uses a dedicated automation key)."
  type        = string
  default     = "~/.ssh/arsenikki"
}


