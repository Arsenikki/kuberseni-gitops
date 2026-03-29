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

# Create API token and grant permissions
pveum user token add terraform@pve provider --privsep=0 --output-format=json
pveum aclmod / -user terraform@pve -role Administrator >/dev/null
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
