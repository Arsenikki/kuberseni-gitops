#!/usr/bin/env bash
set -euo pipefail

# Check VM IPs via qemu-guest-agent
# Usage: ./check-vm-ips.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"

echo "Checking VM IPs via qemu-guest-agent..."
echo

TOKEN=$(sops -d "$TERRAFORM_DIR/secrets.tfvars" | grep proxmox_api_token | awk -F'"' '{print $2}')
PVE_API="https://192.168.1.10:8006/api2/json"

# Pass the auth header via a curl config file on stdin (curl -K -) instead of
# -H on the command line, so the API token is never visible in `ps`/argv.
# Note: -k/--insecure disables TLS cert verification (Proxmox uses a self-signed
# LAN cert); functionality is intentionally preserved here.
auth_config() {
  printf 'header = "Authorization: PVEAPIToken=terraform@pve!provider=%s"\n' "$TOKEN"
}

for vm_id in 1001 1002 1003 2001; do
  # Get VM info from cluster
  vm_info=$(auth_config | curl -sk -K - \
    "$PVE_API/cluster/resources?type=vm" | \
    jq -r ".data[] | select(.vmid == $vm_id)")
  
  name=$(echo "$vm_info" | jq -r '.name')
  node=$(echo "$vm_info" | jq -r '.node')
  state=$(echo "$vm_info" | jq -r '.status')
  
  echo "[$vm_id] $name"
  echo "  Node: $node"
  echo "  State: $state"
  
  if [ "$state" = "running" ]; then
    # Try to get IP from qemu-guest-agent
    ip=$(auth_config | curl -sk -K - \
      "$PVE_API/nodes/$node/qemu/$vm_id/agent/network-get-interfaces" 2>/dev/null | \
      jq -r '.data.result[]? | select(.name == "eth0") | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4") | .["ip-address"]' 2>/dev/null || true)
    
    if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
      echo "  IP: $ip"
    else
      echo "  IP: (guest agent not ready or booting)"
    fi
  else
    echo "  IP: (VM not running)"
  fi
  echo
done
