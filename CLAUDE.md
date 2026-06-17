# CLAUDE.md — kuberseni-gitops

Homelab GitOps: **Talos Linux** Kubernetes on **Proxmox**, managed by **ArgoCD**.
Repo: `github.com/Arsenikki/kuberseni-gitops`. Migrated from k3s+Flux → Talos+ArgoCD.

> Living doc — add hard-won, non-obvious facts here so they don't need re-discovery.
> Operational gotchas also live in Claude's memory (`MEMORY.md`).

## Git Rules

- **Never push directly to `main`** — always open a PR, even for one-liners.
- **Never use `git reset --hard`** — use `git pull --rebase` or `git merge --ff-only` instead.

## Tooling (IMPORTANT)
- **IaC is OpenTofu, NOT Terraform.** Providers come from `registry.opentofu.org`. Running `terraform` fails (wrong registry). Use `tofu` (installed via mise at `~/.local/share/mise/installs/opentofu/`).
- **mise** manages tool versions (`mise.lock`, **pin versions — never `latest`**); **go-task** runs workflows (`infra/Taskfile.yml`, run from `infra/`); **sops** encrypts secrets; **talhelper** renders Talos config; **uv** provides `uvx` for MCP servers.
- Tofu secrets: `infra/terraform/secrets.tfvars` is **sops-encrypted**. Always inject via `sops exec-file secrets.tfvars 'tofu <cmd> -var-file={}'`.
- **ha-mcp**: Claude introspects/controls Home Assistant via the `ha-mcp` MCP server (project `.mcp.json` → `op run -- uvx ha-mcp`; HA long-lived token in 1Password `homelab` vault → `op://homelab/home-assistant/mcp_token`).

## Common commands
- `cd infra && task terraform:plan` / `task terraform:apply` — Proxmox VMs + OPNSense DHCP (wraps sops+tofu)
- `task argocd:bootstrap` / `task argocd:password` / `task argocd:port-forward`
- `task up` (apply) / `task down` (destroy ALL VMs — data loss)
- **kubectl**: context is **`admin@kuberseni`**; kubeconfig at repo-root `kubeconfig`. Flags go **after** the subcommand: `kubectl get pods -n media --context admin@kuberseni` (NOT `kubectl --context X get …` — errors).

## Infra topology
- **Proxmox cluster** `homelab`, 3 nodes: `router` 192.168.1.10 · `minipc` 192.168.1.11 · `nas` 192.168.1.12. API endpoint `192.168.1.10:8006`.
  - SSH to a node: `SSH_AUTH_SOCK= ssh -o IdentitiesOnly=yes -o IdentityAgent=none -i ~/.ssh/arsenikki root@<node-ip>` — the `IdentityAgent=none` is required, else the 1Password SSH agent intercepts and signing fails.
  - `qm <cmd> <vmid>` only works on the node that **hosts** that VM (find host via `pvesh get /nodes/nas/qemu` etc.).
- **VMs**: control-plane-01/02/03 = `1001/1002/1003`; worker-01/02 = `2001/2002`; TrueNAS Scale = `202`; TrueNAS Core = `200` (stopped, pending decommission).
  - worker-01 has Intel iGPU passthrough (Plex HW transcode). CP-01 has the SONOFF Zigbee USB passthrough.
- **Network** 192.168.1.0/24: OPNSense `.1` (runs in Proxmox, holds WAN). DHCP = OPNSense **Kea** (pool .100–.199); reservations are IaC in `infra/terraform/opnsense.tf` (cluster ones derived from `vms.tf` locals). OPNSense managed by `browningluke/opnsense` provider; creds in secrets.tfvars.
- **DNS**: Cloudflare via **external-dns** (incl. bare-metal hosts: `cluster/apps/external-dns/infra-hosts.yaml`), NOT OPNSense Unbound. Apps are served at **apex `*.arsenikki.casa`** (wildcard cert), all → Cilium LB `192.168.1.222`.
- **Storage / TrueNAS Scale** `192.168.1.2` (static, set inside TrueNAS — not DHCP). Serves ZFS pool `main` (single 16TB disk, no redundancy) over NFS. API: `https://192.168.1.2/api/v2.0` (Bearer key in 1Password). k8s media NFS PV is hardcoded to `.2` (`cluster/apps/media/plex/media-pvc.yaml`). Migration history + the data-disk-as-`scsi1` passthrough note: `infra/terraform/truenas-scale.tf` (guarded by `lifecycle.ignore_changes=[disk]`).

## Repo layout
- `cluster/` — ArgoCD: `bootstrap/` (one-time), `argocd/` (root app + app defs), `core/` (infra: cilium, cert-manager, traefik, longhorn, eso, authentik…), `apps/` (user apps by namespace).
- `infra/terraform/` — OpenTofu (Proxmox VMs, OPNSense DHCP). `infra/talos/` — talhelper (`talconfig.yaml`, patches). `infra/scripts/` — bootstrap/migration helpers. `infra/MIGRATION.md`, `infra/Taskfile.yml`.

## Conventions / gotchas
- ArgoCD reconciles from git — **don't fix drift out-of-band; commit it** (selfHeal reverts manual changes). For a maintenance stop, patch `spec.syncPolicy.automated.selfHeal=false` on the Application first.
- Nodes use `deviceSelector: {driver: virtio_net}` (interface is `ens18`/`ens+`); Talos v1.13.2, k8s managed via talhelper.
- **1Password**: two `op` accounts — work `automata.1password.eu`, personal `my.1password.eu` (has the **`homelab`** vault). `op` returns empty inside `$(...)` substitution (TTY detection) — fetch by **item ID** redirected to a temp file, then read it.
