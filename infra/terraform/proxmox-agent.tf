# Scoped Proxmox API access for the paseo-generic agent (claude@pve!paseo)
# Read-only across the whole cluster, plus VM snapshots and vzdump backups. Cannot
# power-manage, reconfigure VMs, touch hosts, or delete backups. (Snapshot rollback
# comes with VM.Snapshot — see the role below.)
#
# Delivery: the token value (sensitive output below) goes into 1Password item
# `paseo-generic-proxmox-token` (homelab vault, field `credential`, format
# `claude@pve!paseo=<secret>`), synced by ESO into paseo-generic and mounted as a file at
# /var/run/secrets/proxmox/token (see cluster/apps/paseo-generic/secrets.yaml):
#   curl -H "Authorization: PVEAPIToken=$(cat /var/run/secrets/proxmox/token)" \
#     https://router.proxmox.arsenikki.casa:8006/api2/json/version
#
# Revoke: delete this file and apply (or Datacenter → Permissions → API Tokens).

locals {
  # Storage the agent may write vzdump backups to.
  proxmox_agent_backup_storage = "local"
}

# No password: the pve-realm user can't log in to the web UI; the token is its only way in.
resource "proxmox_virtual_environment_user" "agent" {
  user_id = "claude@pve"
  comment = "paseo-generic agent (managed by kuberseni-gitops proxmox-agent.tf)"
  enabled = true
}

# Privilege-separated: the token gets only the ACLs below, never the user's.
resource "proxmox_user_token" "agent" {
  user_id               = proxmox_virtual_environment_user.agent.user_id
  token_name            = "paseo"
  comment               = "paseo-generic: read-only + snapshot/backup"
  privileges_separation = true
}

# ⚠️ VM.Snapshot also allows deleting AND rolling back snapshots: PVE 8 accepts either
# VM.Snapshot or VM.Snapshot.Rollback for rollback, so it can't be split off.
# The audit privileges are repeated here because an ACL on a deeper path (/vms,
# /storage/local) replaces the PVEAuditor grant inherited from /, it doesn't add to it.
resource "proxmox_virtual_environment_role" "agent_snapshot" {
  role_id = "AgentSnapshot"
  privileges = [
    "Datastore.AllocateSpace",
    "Datastore.Audit",
    "VM.Audit",
    "VM.Backup",
    "VM.Snapshot",
  ]
}

# A privilege-separated token's effective permissions are the INTERSECTION of its own
# ACLs and its user's, so every grant goes on both. The user has no password, so its
# grants are only reachable through the token.
locals {
  proxmox_agent_grants = {
    # Read-only view of everything: nodes, VMs, configs, storage, tasks, cluster status.
    audit            = { path = "/", role_id = "PVEAuditor" }
    snapshot_vms     = { path = "/vms", role_id = proxmox_virtual_environment_role.agent_snapshot.role_id }
    snapshot_storage = { path = "/storage/${local.proxmox_agent_backup_storage}", role_id = proxmox_virtual_environment_role.agent_snapshot.role_id }
  }
}

resource "proxmox_acl" "agent_user" {
  for_each = local.proxmox_agent_grants

  user_id   = proxmox_virtual_environment_user.agent.user_id
  role_id   = each.value.role_id
  path      = each.value.path
  propagate = true
}

resource "proxmox_acl" "agent_token" {
  for_each = local.proxmox_agent_grants

  token_id  = proxmox_user_token.agent.id
  role_id   = each.value.role_id
  path      = each.value.path
  propagate = true
}

moved {
  from = proxmox_acl.agent_audit
  to   = proxmox_acl.agent_token["audit"]
}
moved {
  from = proxmox_acl.agent_snapshot_vms
  to   = proxmox_acl.agent_token["snapshot_vms"]
}
moved {
  from = proxmox_acl.agent_snapshot_storage
  to   = proxmox_acl.agent_token["snapshot_storage"]
}

output "proxmox_agent_token" {
  description = "claude@pve!paseo API token — copy into 1Password paseo-generic-proxmox-token"
  value       = proxmox_user_token.agent.value
  sensitive   = true
}
