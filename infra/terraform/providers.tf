terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.99"
    }
    opnsense = {
      source  = "browningluke/opnsense"
      version = "~> 0.16.1"
    }
  }

  # Uncomment to use remote state (e.g. an S3-compatible store on TrueNAS)
  # backend "s3" {
  #   bucket = "terraform-state"
  #   key    = "kuberseni/terraform.tfstate"
  #   region = "us-east-1"  # required but ignored by most S3-compatible backends
  #   endpoints = {
  #     s3 = "http://192.168.1.12:9000"
  #   }
  #   skip_credentials_validation = true
  #   skip_requesting_account_id  = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   force_path_style            = true
  # }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # set to false if Proxmox has a trusted TLS cert
}

provider "opnsense" {
  uri        = var.opnsense_url
  api_key    = var.opnsense_api_key
  api_secret = var.opnsense_api_secret
}
