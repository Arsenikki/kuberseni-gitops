---
title: Terraform
description: Terraform
layout: /src/layouts/MainLayout.astro
---

Terraform is used to generated wanted Azure resources. The main ones are:

- Azure storage account - used for data backups
- Azure static web app - used to host Astro-based docs

# Getting started

Terraform provider is configured to use Azure blob storage as an external storage for the tfstate. However, the state cannot be stored there on the first initialization as the storage account doesn't yet exist. For this reason following steps need to be followed for the first run:

1. Temporarily remove following part from the `main.tf` file:
```
backend "azurerm" {
  resource_group_name = "rgkuberseni"
  storage_account_name = "sakuberseni"
  container_name       = "tfstate"
  key                  = "terraform.tfstate"
}
```

2. Execute `terraform init`
3. Execute `terraform apply`
4. Revert the change done in step 1.
5. Execute `terraform init` again, which will ask to transfer the local state to storage account. Select `yes`.
