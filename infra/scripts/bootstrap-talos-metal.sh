#!/usr/bin/env bash
# Bootstrap Talos cluster using metal install approach.
# Run after: terraform apply (which creates VMs booting from ISO)
#
# What this does:
#   1. Waits for each VM to boot into Talos maintenance mode (via DHCP)
#   2. Applies the machine config to each node
#   3. Waits for installation and reboot
#   4. Bootstraps the etcd cluster on the first control plane
#   5. Updates Terraform to remove ISO and set disk boot order
#
# Prerequisites:
#   - terraform apply completed (VMs created, booting from ISO)
#   - talhelper genconfig completed (clusterconfig/ populated)
#   - SSH access to Proxmox nodes
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TALOS_DIR="$REPO_ROOT/infra/talos"
TALOSCONFIG="$TALOS_DIR/clusterconfig/talosconfig"
SSH_OPTS="-o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o IdentityFile=$HOME/.ssh/arsenikki -o IdentityAgent=none"

# Proxmox node IPs
declare -A PVE_NODES=(
  [router]=192.168.1.10
  [minipc]=192.168.1.11
  [nas]=192.168.1.12
)

# VM definitions: name -> "proxmox_node vmid final_ip"
declare -A VMS=(
  [control-plane-01]="router  1001 192.168.1.41"
  [control-plane-02]="minipc  1002 192.168.1.42"
  [control-plane-03]="nas     1003 192.168.1.43"
  [worker-01]="minipc  2001 192.168.1.44"
  [worker-02]="nas     2002 192.168.1.45"
)

# Order matters: CPs first so we can bootstrap etcd
CP_ORDER=(control-plane-01 control-plane-02 control-plane-03)
WORKER_ORDER=(worker-01 worker-02)

get_maintenance_ip() {
  local pve_node=$1
  local vmid=$2
  local pve_ip="${PVE_NODES[$pve_node]}"

  # Query QEMU guest agent for VM IPs
  ssh $SSH_OPTS root@$pve_ip \
    "pvesh get /nodes/$pve_node/qemu/$vmid/agent/network-get-interfaces --output-format json 2>/dev/null \
     | python3 -c \"
import sys,json
ifaces=json.load(sys.stdin)['result']
for i in ifaces:
  for a in i.get('ip-addresses',[]):
    ip=a['ip-address']
    if not (ip.startswith('127') or ip.startswith('fe80') or ip.startswith('169') or ':' in ip):
      print(ip)
      exit()
\"" 2>/dev/null || true
}

apply_config() {
  local name=$1
  read -r pve_node vmid final_ip <<< "${VMS[$name]}"
  local config_file="$TALOS_DIR/clusterconfig/kuberseni-${name}.yaml"

  echo "==> $name: waiting for maintenance mode IP..."
  local maintenance_ip=""
  local attempts=0
  while [[ -z "$maintenance_ip" ]]; do
    maintenance_ip=$(get_maintenance_ip "$pve_node" "$vmid")
    if [[ -z "$maintenance_ip" ]]; then
      ((attempts++))
      if (( attempts % 10 == 0 )); then
        echo "    $name: still waiting... (${attempts}s)"
      fi
      sleep 5
    fi
  done

  echo "==> $name: found at $maintenance_ip, applying config..."
  talosctl apply-config --insecure \
    --nodes "$maintenance_ip" \
    --file "$config_file"

  echo "==> $name: config applied, waiting for install and reboot to $final_ip..."
  # Wait for the node to come up with its static IP
  until talosctl --talosconfig "$TALOSCONFIG" -n "$final_ip" version >/dev/null 2>&1; do
    sleep 5
  done
  echo "==> $name: online at $final_ip"
}

echo "=== Phase 1: Apply machine configs to all nodes ==="
for name in "${CP_ORDER[@]}"; do
  apply_config "$name"
done

for name in "${WORKER_ORDER[@]}"; do
  apply_config "$name" &
done
wait
echo "All nodes configured."

echo ""
echo "=== Phase 2: Bootstrap etcd on control-plane-01 ==="
talosctl --talosconfig "$TALOSCONFIG" -n 192.168.1.41 bootstrap
echo "etcd bootstrapped."

echo ""
echo "=== Phase 3: Wait for cluster to be healthy ==="
until kubectl --kubeconfig "$TALOS_DIR/clusterconfig/kubeconfig" get nodes 2>/dev/null | grep -qE "Ready"; do
  sleep 5
done
kubectl --kubeconfig "$TALOS_DIR/clusterconfig/kubeconfig" get nodes

echo ""
echo "=== Phase 4: Label worker nodes for Longhorn storage ==="
kubectl --kubeconfig "$TALOS_DIR/clusterconfig/kubeconfig" \
  label node worker-01 worker-02 node.longhorn.io/create-default-disk=true --overwrite

echo ""
echo "=== Done: Talos cluster is up with metal install ==="
echo ""
echo "Next steps:"
echo "  1. Remove ISO from VMs and set disk boot order:"
echo "     Edit vms.tf: remove cdrom blocks, change boot_order to [\"scsi0\"]"
echo "     terraform apply"
echo "  2. Run bootstrap-cluster.sh to install ArgoCD + ESO + apps"
