#!/bin/bash
# This file should only be used as a cheatsheet/reference of a working setup.
# Inspiration can and should be taken from it. 
set -euox pipefail

# Talos cluster deployment script
# Usage: ./setup-talos-cluster.sh [cluster_name] [node1_ip] [node2_ip] [node3_ip] [issuer_hostpath] [aws_region] [s3_bucket] [talos_image_uri] [cilium_version] [output_dir]
# Example: ./setup-talos-cluster.sh linq-riccardo-dev 192.168.40.101 192.168.40.100 192.168.40.155 https://bucket.s3.amazonaws.com eu-west-1 bucket-name factory.talos.dev/metal-installer/a5bcfa0341cdda9d1aebbf50112479667a7ea92983eade154bab14cbb4319752:v1.10.7 1.18.0 /path/to/output/dir

# Source shared utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/k8s-utils.sh"

# Check required commands at the beginning
echo "🔍 Checking required commands..."

if ! command -v talosctl &> /dev/null; then
    echo "❌ talosctl not found. Please install talosctl first."
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please install kubectl first."
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo "❌ helm not found. Please install helm first."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "❌ jq not found. Please install jq first."
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo "❌ aws not found. Please install aws-cli first."
    exit 1
fi

echo "✅ All required commands are available"

# Parse command line arguments
CLUSTER_NAME="${1:-}"
IP1="${2:-}"
IP2="${3:-}"
IP3="${4:-}"
ISSUER_HOSTPATH="${5:-}"
AWS_REGION="${6:-}"
S3_BUCKET="${7:-}"
TALOS_IMAGE_URI="${8:-}"
CILIUM_VERSION="${9:-}"
OUTPUT_DIR="${10:-}"
PLATFORM="${11:-vm}"  # "vm" or "baremetal"
INSTALL_DISK="${12:-/dev/sda}" # Talos installation disk
# shellcheck disable=SC2034
DATA_DISK="${13:-}"   # Data/user volume disk (optional, empty means no user volume)
# Note: DATA_DISK is passed but not used in this script (used by Terraform module)

# Validate parameters (only IP1 is required, IP2 and IP3 are optional)
if [ -z "$CLUSTER_NAME" ] || [ -z "$IP1" ] || [ -z "$ISSUER_HOSTPATH" ] || [ -z "$AWS_REGION" ] || [ -z "$S3_BUCKET" ] || [ -z "$TALOS_IMAGE_URI" ] || [ -z "$CILIUM_VERSION" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "❌ Missing required parameters"
    echo "Usage: $0 [cluster_name] [node1_ip] [node2_ip] [node3_ip] [issuer_hostpath] [aws_region] [s3_bucket] [talos_image_uri] [cilium_version] [output_dir] [platform] [install_disk] [data_disk]"
    echo "Note: node2_ip and node3_ip are optional (can be empty)"
    exit 1
fi

# Validate platform
if [ "$PLATFORM" != "vm" ] && [ "$PLATFORM" != "baremetal" ]; then
    echo "❌ Invalid platform: $PLATFORM (must be 'vm' or 'baremetal')"
    exit 1
fi

# Build NODES array, filtering out empty IPs
NODES=()
[ -n "$IP1" ] && NODES+=("$IP1")
[ -n "$IP2" ] && NODES+=("$IP2")
[ -n "$IP3" ] && NODES+=("$IP3")

if [ ${#NODES[@]} -eq 0 ]; then
    echo "❌ ERROR: At least one node IP is required"
    exit 1
fi

echo "🔧 Using provided node IPs: ${NODES[*]} (${#NODES[@]} node(s))"

CONTROL_PLANE_ENDPOINT="${NODES[0]}:6443"
# Use provided output_dir (should be absolute path from Terraform)
TMP_DIR="$OUTPUT_DIR"

echo "✅ Found ${#NODES[@]} nodes: ${NODES[*]}"
echo "✅ Control plane endpoint: $CONTROL_PLANE_ENDPOINT"

# Create cluster-specific tmp directory
mkdir -p "$TMP_DIR"

# Clean up old configuration files to avoid using stale IPs
rm -f "$TMP_DIR/kubeconfig" "$TMP_DIR/talosconfig" "$TMP_DIR/controlplane.yaml" "$TMP_DIR/worker.yaml"

# Set environment variables
export TALOSCONFIG="$TMP_DIR/talosconfig"
export KUBECONFIG="$TMP_DIR/kubeconfig"

# Get AWS credentials from Secrets Manager (for ECR access via env vars)
echo "🔍 Reading AWS credentials from Secrets Manager..."
SECRETS_JSON=$(aws secretsmanager get-secret-value --secret-id clusters --region "$AWS_REGION" --query SecretString --output text 2>/dev/null || echo "{}")

if [ "$SECRETS_JSON" = "{}" ] || [ -z "$SECRETS_JSON" ]; then
    echo "❌ ERROR: Failed to read secrets from Secrets Manager"
    exit 1
fi

AWS_ACCESS_KEY_ID=$(echo "$SECRETS_JSON" | jq -r '.AWS_ACCESS_KEY_ID // empty' 2>/dev/null || echo "")
AWS_SECRET_ACCESS_KEY=$(echo "$SECRETS_JSON" | jq -r '.AWS_SECRET_ACCESS_KEY // empty' 2>/dev/null || echo "")

# Validate that AWS credentials are present
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "❌ ERROR: AWS credentials (AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY) are required but not found in Secrets Manager"
    echo "   Please ensure the 'clusters' secret in Secrets Manager contains both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
    exit 1
fi

echo "✅ AWS credentials retrieved from Secrets Manager"

# Create config patch file with OIDC/IRSA configuration, AWS env vars, and ECR credential provider
cat > "$TMP_DIR/first_install.yaml" <<EOF
debug: true
cluster:
  allowSchedulingOnControlPlanes: true
  apiServer:
    extraArgs:
      service-account-issuer: "${ISSUER_HOSTPATH}"
      service-account-jwks-uri: "${ISSUER_HOSTPATH}/keys.json"
  network:
    cni:
      name: "none"
    podSubnets:
      - "172.16.0.0/16"
    serviceSubnets:
      - "172.17.0.0/16"
  proxy:
    disabled: true
machine:
  features:
    kubePrism:
      enabled: true
      port: 7445
  sysctls:
    net.core.rmem_max: "7500000"
    net.core.wmem_max: "7500000"
    net.ipv4.ping_group_range: "1 65535"
  env:
    AWS_ACCESS_KEY_ID: "${AWS_ACCESS_KEY_ID}"
    AWS_SECRET_ACCESS_KEY: "${AWS_SECRET_ACCESS_KEY}"
    AWS_DEFAULT_REGION: "${AWS_REGION}"
  kubelet:
    credentialProviderConfig:
      apiVersion: kubelet.config.k8s.io/v1
      kind: CredentialProviderConfig
      providers:
        - apiVersion: credentialprovider.kubelet.k8s.io/v1
          defaultCacheDuration: 12h
          matchImages:
            - '*.dkr.ecr.*.amazonaws.com'
          name: ecr-credential-provider
EOF
echo "✅ OIDC/IRSA configuration and AWS env vars added to patch"

printf "Patch is:\n"
cat "$TMP_DIR/first_install.yaml"

# Generate Talos config with patch
NODE_SANS=$(IFS=,; echo "${NODES[*]}")

talosctl gen config "$CLUSTER_NAME" "https://$CONTROL_PLANE_ENDPOINT" \
    --output-dir "$TMP_DIR" \
    --config-patch @"$TMP_DIR/first_install.yaml" \
    --install-disk "$INSTALL_DISK" \
    --install-image "$TALOS_IMAGE_URI" \
    --kubernetes-version "v1.33.4" \
    --additional-sans "$NODE_SANS"

echo "✅ Configuration generated and patched"

# check_node_reachable and wait_for_talos_api functions are now sourced from k8s-utils.sh

# Wait for Talos API to be ready on all nodes before applying config
echo "⏳ Waiting for Talos API to be ready on all nodes..."
for node in "${NODES[@]}"; do
   echo "Waiting for Talos API on node $node..."
   wait_for_talos_api "$node"
done

# Apply to all nodes (all are control planes)
for node in "${NODES[@]}"; do
    echo "Applying to control plane node: $node"
    talosctl apply-config --insecure --nodes "$node" --file "$TMP_DIR/controlplane.yaml"
done

echo "Waiting for nodes to be ready..."
sleep 60

for node in "${NODES[@]}"; do
   check_node_reachable "$node" 50000
done

# Bootstrap the cluster
echo "Bootstrapping cluster on ${NODES[0]}..."
talosctl bootstrap -n "${NODES[0]}" -e "${NODES[0]}" || echo "Cluster already bootstrapped"
echo "Waiting for cluster to be ready..."
sleep 60

for node in "${NODES[@]}"; do
   check_node_reachable "$node" 6443
done

# Generate kubeconfig
echo "Generating kubeconfig..."
talosctl config endpoint "${NODES[0]}"
talosctl kubeconfig "$TMP_DIR/kubeconfig" --nodes "${NODES[0]}"
echo "Files created:"
ls -la "$TMP_DIR"
export KUBECONFIG="$TMP_DIR/kubeconfig"

echo "⏳ Waiting for nodes to join the cluster..."
sleep 30
