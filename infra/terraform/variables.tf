# Proxmox Provider Configuration
## Provider Login Variables
variable "pve_token_id" {
  description = "Proxmox API Token Name."
  sensitive   = true
}

variable "pve_token_secret" {
  description = "Proxmox API Token Value."
  sensitive   = true
}

variable "pve_api_url" {
  description = "Proxmox API Endpoint, e.g. 'https://pve.example.com/api2/json'"
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("(?i)^http[s]?://.*/api2/json$", var.pve_api_url))
    error_message = "Proxmox API Endpoint Invalid. Check URL - Scheme and Path required."
  }
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key for Proxmox host access"
  type        = string
}

# Node Configuration
variable "node_name" {
  description = "Proxmox node name where VMs will be created"
  type        = string
}

# Cluster Configuration
variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
  default     = "talos-cluster"
}

variable "node_configs" {
  description = "List of node type configurations"
  type = list(object({
    name              = string
    role              = string
    count             = number
    cpu_cores         = number
    memory_mb         = number
    os_disk_size_gb   = number
    data_disk_size_gb = number
  }))
}

variable "vm_id_base" {
  description = "Base VM ID for numbering VMs"
  type        = number
  default     = 1000
}

variable "talos_image_url" {
  description = "URL for the Talos Linux image"
  type        = string
}

# Additional Configuration
variable "additional_tags" {
  description = "Additional tags to apply to VMs"
  type        = list(string)
  default     = []
}
