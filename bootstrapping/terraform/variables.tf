variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
  default     = "12d32421-ff43-4cd5-9e59-a74ba2e7a4c4"   
}

variable "rg_name" {
  description = "Azure resource group name"
  type        = string
  default     = "rgkuberseni"
}

variable "rg_location" {
  description = "Azure resource group location"
  type        = string
  default     = "North Europe"
}

variable "st_name" {
  description = "Azure storage account name"
  type        = string
  default     = "stkuberseni"
}

variable "storage_container_list" {
  description = "List of storage container names"
  type        = set(string)
  default       = ["tfstate", "photo-backup", "longhorn-backup"]
}