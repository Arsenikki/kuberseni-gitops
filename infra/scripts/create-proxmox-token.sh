#!/usr/bin/env bash
set -e

# Proxmox API Token Creation Script
# Creates terraform@pve user and API token, saves to encrypted file

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
TFVARS_FILE="$TERRAFORM_DIR/terraform.tfvars"

# Prompt for Proxmox host
read -p "Proxmox host IP [192.168.1.10]: " PROXMOX_HOST
PROXMOX_HOST=${PROXMOX_HOST:-192.168.1.10}

SSH_KEY="${SSH_KEY:-$HOME/.ssh/arsenikki}"

echo "Creating Terraform user and API token on $PROXMOX_HOST..."

# Capture token creation output
TOKEN_OUTPUT=$(ssh -i "$SSH_KEY" root@"$PROXMOX_HOST" 'bash -s' <<'EOF'
set -e

# Create terraform user if not exists
if ! pveum user list | grep -q "terraform@pve"; then
  pveum user add terraform@pve --comment "Terraform automation user" >/dev/null
fi

# Delete old token if exists
if pveum user token list terraform@pve 2>/dev/null | grep -q "provider"; then
  pveum user token remove terraform@pve provider >/dev/null
fi

# Least-privilege role for OpenTofu (bpg/proxmox provider).
# Instead of granting the built-in Administrator role, we define a custom role
# that grants ONLY the privileges OpenTofu needs to clone/configure/manage VMs,
# allocate datastore space, use SDN/mappings, and audit the system. This limits
# blast radius if the token leaks.
TERRAFORM_PRIVS="VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Audit VM.PowerMgmt VM.Migrate Datastore.Allocate Datastore.AllocateSpace Datastore.Audit Pool.Allocate Sys.Audit Sys.Console Sys.Modify SDN.Use Mapping.Use Mapping.Audit"

# Create (or update) the custom role idempotently.
if pveum role list | grep -q "TerraformProv"; then
  pveum role modify TerraformProv -privs "$TERRAFORM_PRIVS" >/dev/null
else
  pveum role add TerraformProv -privs "$TERRAFORM_PRIVS" >/dev/null
fi

# Create API token with privilege separation enabled (--privsep=1) so the token
# gets its own ACL entries rather than inheriting all of the user's permissions.
pveum user token add terraform@pve provider --privsep=1 --output-format=json

# Grant the least-privilege role to the token itself (not a blanket
# Administrator grant on the user). Scoped at "/" because OpenTofu manages VMs
# across nodes and needs datastore/SDN access cluster-wide.
pveum aclmod / -token 'terraform@pve!provider' -role TerraformProv >/dev/null
EOF
)

# Extract token value from JSON output
TOKEN_SECRET=$(echo "$TOKEN_OUTPUT" | grep -o '"value":"[^"]*"' | cut -d'"' -f4)

# Create terraform.tfvars file
cat > "$TFVARS_FILE" <<TFVARS
proxmox_endpoint  = "https://$PROXMOX_HOST:8006/"
proxmox_api_token = "terraform@pve!provider=$TOKEN_SECRET"
network_gateway   = "192.168.1.1"
TFVARS

echo "✅ Token created and saved to terraform.tfvars"

# Encrypt the file
echo "Encrypting terraform.tfvars with SOPS..."
sops -e -i "$TFVARS_FILE"

echo "✅ Done! terraform.tfvars is encrypted and ready to commit"
