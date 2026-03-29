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
  default     = "v1.12.6"
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

# OPNSense provider configuration
variable "opnsense_url" {
  description = "OPNSense API URL, e.g. https://192.168.1.1"
  type        = string
  default     = "https://192.168.1.1"
}

variable "opnsense_api_key" {
  description = "OPNSense API key (from System → Access → Users → API keys)"
  type        = string
  sensitive   = true
}

variable "opnsense_api_secret" {
  description = "OPNSense API secret (from System → Access → Users → API keys)"
  type        = string
  sensitive   = true
}
