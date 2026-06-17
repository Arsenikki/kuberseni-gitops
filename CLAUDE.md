# CLAUDE.md — kuberseni-gitops

Homelab GitOps: **Talos Linux** Kubernetes on **Proxmox**, managed by **ArgoCD**.

## Git Rules

- **Never push directly to `main`** — always open a PR, even for one-liners.
- **Never use `git reset --hard`** — use `git pull --rebase` or `git merge --ff-only` instead.

## Tooling

- **IaC: OpenTofu** (`tofu`), not terraform. Providers from `registry.opentofu.org`. Secrets in `infra/tofu/secrets.tfvars` are sops-encrypted — inject via `sops exec-file secrets.tfvars 'tofu <cmd> -var-file={}'`.
- **mise** manages tool versions (pin, never `latest`); **go-task** runs workflows (`infra/Taskfile.yml`); **talhelper** renders Talos config (`infra/talos/talconfig.yaml`).
- **ha-mcp**: controls Home Assistant via `.mcp.json` → `op run -- uvx ha-mcp`. Token at `op://homelab/home-assistant/mcp_token`.

## Common commands

- `cd infra && task tofu:plan` / `task tofu:apply` — Proxmox VMs + OPNSense DHCP
- `task argocd:bootstrap` / `task argocd:password` / `task argocd:port-forward`
- `task up` (apply) / `task down` (destroy ALL VMs — data loss)
- **kubectl context**: `admin@kuberseni`. Put flags **after** the subcommand: `kubectl get pods -n media --context admin@kuberseni`.

## Infra

- **Proxmox** `homelab`, 3 nodes: `router` .10 · `minipc` .11 · `nas` .12. SSH: `SSH_AUTH_SOCK= ssh -o IdentityAgent=none -i ~/.ssh/arsenikki root@<ip>` (IdentityAgent=none required — 1Password agent intercepts otherwise).
- **VMs**: CP-01/02/03 = `1001–1003`; worker-01/02 = `2001/2002`; TrueNAS Scale = `202`. worker-01 has Intel iGPU passthrough (Plex). CP-01 has SONOFF Zigbee USB passthrough.
- **Network**: OPNSense `.1` (WAN). DHCP via Kea (.100–.199). DNS via Cloudflare external-dns — apps at `*.arsenikki.casa` → Cilium LB `192.168.1.222`.
- **Storage**: TrueNAS Scale `192.168.1.2`, ZFS over NFS. API Bearer key in 1Password homelab vault.

## Repo layout

- `cluster/` — ArgoCD apps: `bootstrap/`, `argocd/`, `core/` (cilium, cert-manager, traefik, longhorn, eso, authentik), `apps/` (user apps by namespace).
- `infra/tofu/` — OpenTofu (Proxmox VMs, OPNSense). `infra/talos/` — talhelper config + patches.

## Gotchas

- ArgoCD selfHeals — **don't fix drift manually; commit it**. To pause: set `spec.syncPolicy.automated.selfHeal=false` on the Application.
- **1Password**: personal account `my.1password.eu`, `homelab` vault. `op` returns empty in `$(...)` — fetch by item ID to a temp file instead.
