#!/usr/bin/env bash
set -euo pipefail

# Update OPNSense DHCP static mappings for Talos VMs
# Requires: OPNSense API key/secret passed as arguments
#
# SETUP:
# 1. Generate API key in OPNSense: System → Access → Users → root → API keys
# 2. Run: task opnsense:update-dhcp
#
# MANUAL ALTERNATIVE:
# If the API approach fails, add these manually in OPNSense UI:
# Services → DHCPv4 → [LAN] → DHCP Static Mappings for this Interface
#   - Use the MAC/IP pairs from: cd terraform && tofu output

OPNSENSE_HOST="${OPNSENSE_HOST:-192.168.1.1}"
OPNSENSE_API_KEY="${1:-}"
OPNSENSE_API_SECRET="${2:-}"

if [[ -z "$OPNSENSE_API_KEY" ]] || [[ -z "$OPNSENSE_API_SECRET" ]]; then
    echo "ERROR: OPNSense API credentials required"
    echo "Usage: $0 <api_key> <api_secret>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

echo "=== Fetching Terraform outputs ==="
cd "$TF_DIR"

# Get outputs as JSON
OUTPUTS=$(tofu output -json)

# Parse control plane MACs and IPs
echo "$OUTPUTS" | jq -r '.controlplane_macs.value | to_entries[] | "\(.key),\(.value)"' | while IFS=, read -r hostname mac; do
    ip=$(echo "$OUTPUTS" | jq -r ".controlplane_ips.value[\"$hostname\"]")
    echo "Control Plane: $hostname - MAC: $mac - IP: $ip"

    # OPNSense API call to add/update DHCP static mapping
    # API endpoint: /api/dhcpv4/leases/addStaticMap
    curl -s -k -u "$OPNSENSE_API_KEY:$OPNSENSE_API_SECRET" \
        -X POST "https://$OPNSENSE_HOST/api/dhcpv4/leases/addStaticMap" \
        -H "Content-Type: application/json" \
        -d "{
            \"staticmap\": {
                \"mac\": \"$mac\",
                \"ipaddr\": \"$ip\",
                \"hostname\": \"$hostname\",
                \"descr\": \"Talos control plane node\"
            }
        }" | jq -r '.result // .message // .'
done

# Parse worker MACs and IPs
echo "$OUTPUTS" | jq -r '.worker_macs.value | to_entries[] | "\(.key),\(.value)"' | while IFS=, read -r hostname mac; do
    ip=$(echo "$OUTPUTS" | jq -r ".worker_ips.value[\"$hostname\"]")
    echo "Worker: $hostname - MAC: $mac - IP: $ip"

    curl -s -k -u "$OPNSENSE_API_KEY:$OPNSENSE_API_SECRET" \
        -X POST "https://$OPNSENSE_HOST/api/dhcpv4/leases/addStaticMap" \
        -H "Content-Type: application/json" \
        -d "{
            \"staticmap\": {
                \"mac\": \"$mac\",
                \"ipaddr\": \"$ip\",
                \"hostname\": \"$hostname\",
                \"descr\": \"Talos worker node\"
            }
        }" | jq -r '.result // .message // .'
done

echo ""
echo "=== Applying DHCP configuration ==="
# Apply the changes
curl -s -k -u "$OPNSENSE_API_KEY:$OPNSENSE_API_SECRET" \
    -X POST "https://$OPNSENSE_HOST/api/dhcpv4/service/reconfigure" \
    | jq -r '.status // .'

echo ""
echo "✅ DHCP static mappings updated in OPNSense"
echo "Note: You may need to reboot the VMs for them to get the new IPs"
