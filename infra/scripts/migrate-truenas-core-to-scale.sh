#!/usr/bin/env bash
# migrate-truenas-core-to-scale.sh
#
# Migrates ZFS pool from TrueNAS Core (vm 200) to TrueNAS Scale (vm 201)
# using Option B: pool export from Core, HDD detach/attach in Proxmox,
# pool import in Scale.
#
# Prerequisites:
#   - TrueNAS Scale VM installed and configured at 192.168.1.3
#   - NFS shares configured on Scale to match Core's paths
#   - All consumers tested and working with Scale's temporary NFS
#   - op CLI signed in: eval $(op signin --account my.1password.eu)
#
# Usage:
#   bash migrate-truenas-core-to-scale.sh [--dry-run]

set -euo pipefail

PROXMOX_HOST="https://192.168.1.10:8006"
TRUENAS_CORE_IP="192.168.1.2"
TRUENAS_SCALE_IP="192.168.1.3"
CORE_VM_ID="200"
SCALE_VM_ID="201"
PROXMOX_NODE="nas"
CONTEXT="admin@kuberseni"
DRY_RUN=false

# HDD passthrough device ID (the ZFS pool disk)
# Update this if you have multiple pool disks
HDD_DEVICE="/dev/disk/by-id/ata-ST16000NM000J-2TW103_ZR55Q0MR"
ZFS_POOL_NAME="main"

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

run() {
  if $DRY_RUN; then
    echo "[DRY RUN] $*"
  else
    "$@"
  fi
}

PROXMOX_TOKEN=$(cd "$(dirname "$0")/../terraform" && \
  sops exec-file secrets.tfvars 'grep proxmox_api_token {} | cut -d= -f2 | tr -d " \""')

pve() {
  curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" "$PROXMOX_HOST/api2/json/$@"
}

pve_post() {
  local path="$1"; shift
  curl -sk -X POST -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$@" "$PROXMOX_HOST/api2/json/$path"
}

echo "======================================================"
echo "  TrueNAS Core → Scale Migration (Option B)"
echo "======================================================"
echo ""
echo "Core: $TRUENAS_CORE_IP (vm $CORE_VM_ID)"
echo "Scale: $TRUENAS_SCALE_IP (vm $SCALE_VM_ID)"
echo "Pool: $ZFS_POOL_NAME"
echo "HDD: $HDD_DEVICE"
$DRY_RUN && echo "(DRY RUN mode — no changes will be made)"
echo ""

# ── Step 1: Stop write-heavy workloads ─────────────────────────────────────
echo "Step 1: Scaling down write-heavy workloads..."
run kubectl --context $CONTEXT scale deployment/qbittorrent -n media --replicas=0
run kubectl --context $CONTEXT scale deployment/plex -n media --replicas=0
echo "  Waiting for pods to stop..."
run kubectl --context $CONTEXT wait pod -n media \
  -l 'app.kubernetes.io/name in (qbittorrent,plex)' \
  --for=delete --timeout=60s 2>/dev/null || true
echo "  ✓ Workloads stopped"

# ── Step 2: Export ZFS pool from TrueNAS Core ──────────────────────────────
echo ""
echo "Step 2: Exporting ZFS pool from TrueNAS Core..."
echo "  ⚠️  You must manually export the pool in the TrueNAS Core UI:"
echo "     Storage → Pools → $ZFS_POOL_NAME → ⋮ → Export/Disconnect"
echo "     (Check 'Confirm Export' and 'Detach devices' = OFF)"
echo ""
read -p "  Press ENTER once the pool is exported in TrueNAS Core UI..."

# ── Step 3: Detach HDD from Core VM in Proxmox ─────────────────────────────
echo ""
echo "Step 3: Detaching HDD from TrueNAS Core VM ($CORE_VM_ID)..."

# Remove scsi2 (the HDD passthrough) from Core VM config
run pve_post "nodes/$PROXMOX_NODE/qemu/$CORE_VM_ID/config" \
  '{"delete":"scsi2"}' > /dev/null
echo "  ✓ HDD detached from Core VM"

# ── Step 4: Attach HDD to Scale VM ─────────────────────────────────────────
echo ""
echo "Step 4: Attaching HDD to TrueNAS Scale VM ($SCALE_VM_ID)..."

run pve_post "nodes/$PROXMOX_NODE/qemu/$SCALE_VM_ID/config" \
  "{\"scsi2\":\"$HDD_DEVICE,backup=0\"}" > /dev/null
echo "  ✓ HDD attached to Scale VM"

# ── Step 5: Import pool in TrueNAS Scale ───────────────────────────────────
echo ""
echo "Step 5: Import ZFS pool in TrueNAS Scale..."
echo "  ⚠️  You must manually import the pool in the TrueNAS Scale UI:"
echo "     Storage → Import Pool → select $ZFS_POOL_NAME → Import"
echo ""
read -p "  Press ENTER once the pool is imported in TrueNAS Scale UI..."

# ── Step 6: Verify NFS mounts from Kubernetes ──────────────────────────────
echo ""
echo "Step 6: Verifying NFS mount from Kubernetes..."
NFS_PATH="/mnt/main/nfs/vols/pvc-000f1e6c-bf36-4259-9108-0a8f52666cc4"
POD=$(kubectl --context $CONTEXT get pod -n media \
  -l app.kubernetes.io/name=sonarr -o name 2>/dev/null | head -1)

if [ -n "$POD" ]; then
  FILE_COUNT=$(kubectl --context $CONTEXT exec $POD -n media -- \
    ls /data/ 2>/dev/null | wc -l || echo "0")
  echo "  NFS mount check: $FILE_COUNT items in /data/"
  [ "$FILE_COUNT" -gt 0 ] && echo "  ✓ NFS mount working" || echo "  ⚠️  NFS mount may be empty"
fi

# ── Step 7: Swap IPs ────────────────────────────────────────────────────────
echo ""
echo "Step 7: IP reassignment"
echo "  Current: Core=$TRUENAS_CORE_IP, Scale=$TRUENAS_SCALE_IP"
echo "  Target:  Scale takes $TRUENAS_CORE_IP (Kubernetes PV doesn't need updating)"
echo ""
echo "  ⚠️  In TrueNAS Scale web UI:"
echo "     Network → Interfaces → set IP to $TRUENAS_CORE_IP"
echo "  ⚠️  In TrueNAS Core (before decommission):"
echo "     Change to a different IP or shut down"
echo ""
read -p "  Press ENTER once IPs have been swapped..."

# ── Step 8: Restore workloads ───────────────────────────────────────────────
echo ""
echo "Step 8: Restoring workloads..."
run kubectl --context $CONTEXT scale deployment/qbittorrent -n media --replicas=1
run kubectl --context $CONTEXT scale deployment/plex -n media --replicas=1
echo "  ✓ Workloads restored"

# ── Step 9: Final validation ────────────────────────────────────────────────
echo ""
echo "Step 9: Final validation..."
run kubectl --context $CONTEXT rollout status deployment/qbittorrent -n media --timeout=2m
run kubectl --context $CONTEXT rollout status deployment/plex -n media --timeout=5m

echo ""
echo "======================================================"
echo "  ✅ Migration complete!"
echo "======================================================"
echo ""
echo "Next steps:"
echo "  1. Verify all apps work correctly for a few days"
echo "  2. Shut down TrueNAS Core VM: tofu apply -var='truenas_core_running=false'"
echo "  3. Remove truenas-core VM and ISO from Terraform when confident"
