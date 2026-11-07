# Scoped Proxmox API access for the paseo-generic agent (claude@pve!paseo)
# Read-only across the whole cluster, plus VM snapshots and vzdump backups. Cannot
# roll back, power-manage, reconfigure VMs, touch hosts, or delete backups.
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

# VM.Snapshot also allows deleting snapshots (Proxmox has no separate privilege);
# rollback needs VM.Snapshot.Rollback, which is deliberately left out.
resource "proxmox_virtual_environment_role" "agent_snapshot" {
  role_id = "AgentSnapshot"
  privileges = [
    "Datastore.AllocateSpace",
    "VM.Backup",
    "VM.Snapshot",
  ]
}

# Read-only view of everything: nodes, VMs, configs, storage, tasks, cluster status.
resource "proxmox_acl" "agent_audit" {
  token_id  = proxmox_user_token.agent.id
  role_id   = "PVEAuditor"
  path      = "/"
  propagate = true
}

resource "proxmox_acl" "agent_snapshot_vms" {
  token_id  = proxmox_user_token.agent.id
  role_id   = proxmox_virtual_environment_role.agent_snapshot.role_id
  path      = "/vms"
  propagate = true
}

resource "proxmox_acl" "agent_snapshot_storage" {
  token_id  = proxmox_user_token.agent.id
  role_id   = proxmox_virtual_environment_role.agent_snapshot.role_id
  path      = "/storage/${local.proxmox_agent_backup_storage}"
  propagate = true
}

output "proxmox_agent_token" {
  description = "claude@pve!paseo API token — copy into 1Password paseo-generic-proxmox-token"
  value       = proxmox_user_token.agent.value
  sensitive   = true
}
