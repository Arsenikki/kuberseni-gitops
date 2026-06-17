# CLAUDE.md — kuberseni-gitops

Homelab GitOps: **Talos Linux** Kubernetes on **Proxmox**, managed by **ArgoCD**.

## Git Rules

- **Never push directly to `main`** — always open a PR, even for one-liners.
- **Never use `git reset --hard`** — use `git pull --rebase` or `git merge --ff-only` instead.

## Tooling

- **IaC: OpenTofu** (`tofu`), not terraform. Providers from `registry.opentofu.org`. Secrets in `infra/tofu/secrets.tfvars` are sops-encrypted — inject via `sops exec-file secrets.tfvars 'tofu <cmd> -var-file={}'`.
- **mise** manages tool versions (pin, never `latest`); **go-task** runs workflows (`infra/Taskfile.yml`); **talhelper** renders Talos config (`infra/talos/talconfig.yaml`).
- **ha-mcp**: controls Home Assistant via `.mcp.json` → `op run -- uvx ha-mcp`.

## Common commands

- `cd infra && task tofu:plan` / `task tofu:apply` — Proxmox VMs + OPNSense DHCP
- `task argocd:bootstrap` / `task argocd:password` / `task argocd:port-forward`
- `task up` (apply) / `task down` (destroy ALL VMs — data loss)
- **kubectl context**: set in `kubeconfig` at repo root. Put flags **after** the subcommand (`kubectl get pods -n foo --context ...`).

## Infra

- **Proxmox** cluster with control-plane and worker VMs. worker-01 has Intel iGPU passthrough (Plex). CP-01 has SONOFF Zigbee USB passthrough.
- **Network**: OPNSense (WAN + DHCP). DNS via Cloudflare external-dns. Apps behind Cilium LoadBalancer.
- **Storage**: TrueNAS Scale over NFS.
- **SSH to Proxmox nodes**: requires `IdentityAgent=none` — the 1Password SSH agent intercepts otherwise and signing fails.

## Repo layout

- `cluster/` — ArgoCD apps: `bootstrap/`, `argocd/`, `core/` (cilium, cert-manager, traefik, longhorn, eso, authentik), `apps/` (user apps by namespace).
- `infra/tofu/` — OpenTofu (Proxmox VMs, OPNSense). `infra/talos/` — talhelper config + patches.

## Gotchas

- ArgoCD selfHeals — **don't fix drift manually; commit it**. To pause: set `spec.syncPolicy.automated.selfHeal=false` on the Application.
- `op` returns empty in `$(...)` subshells (TTY detection) — fetch secrets by item ID to a temp file instead.
