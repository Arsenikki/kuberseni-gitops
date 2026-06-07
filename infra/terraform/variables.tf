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

variable "attach_iso" {
  description = "Attach Talos metal ISO for initial installation. Set to false after first boot to boot from disk."
  type        = bool
  default     = true
}
