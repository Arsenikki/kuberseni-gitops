terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.40.0"
    }
  }
  backend "azurerm" {
    resource_group_name = "rgkuberseni"
    storage_account_name = "stkuberseni"
    container_name       = "tfstate"
    key                  = "terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

resource "azurerm_resource_group" "kuberseni" {
  name     = var.rg_name
  location = var.rg_location
}

resource "azurerm_storage_account" "kuberseni" {
  name                          = var.st_name
  resource_group_name           = var.rg_name
  location                      = var.rg_location
  account_tier                  = "Standard"
  account_replication_type      = "LRS"
  public_network_access_enabled = "true"
  min_tls_version               = "TLS1_2"
}

resource "azurerm_storage_container" "containers" {
  for_each = var.storage_container_list
  name                  = each.value
  storage_account_name  = var.st_name
  container_access_type = "private"
}

resource "azurerm_storage_account_network_rules" "default" {
  storage_account_id = azurerm_storage_account.kuberseni.id
  default_action     = "Deny"
  ip_rules           = ["84.248.0.0/16", "84.249.0.0/16", "84.250.0.0/16", "84.251.0.0/16"]
}