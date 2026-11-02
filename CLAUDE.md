# CLAUDE.md — kuberseni-gitops

Homelab GitOps: **Talos Linux** Kubernetes on **Proxmox**, managed by **ArgoCD**.

## Git Rules

- **Never push directly to `main`** — always open a PR, even for one-liners.
- **Never use `git reset --hard`** — use `git pull --rebase` or `git merge --ff-only` instead.

## Working alongside other sessions

Several agent sessions (and Jeeves) change this repo at the same time, and a merge
here is a deploy. Past collisions: duplicate fixes for the same problem (#774/#800,
#776/#798) and PRs built on an outdated `main`.

- **Before you start**, run `gh pr list --state open` and look for PRs touching the
  same app or paths (`cluster/apps/<ns>/…`, `infra/…`). If one exists, build on it
  or comment there instead of opening a second fix.
- **Branch from current `main`** (`git fetch origin`, then branch off `origin/main`).
  Before opening a PR, `git rebase origin/main` and re-run the checks; once the PR is
  pushed, merge `origin/main` into it instead of rebasing.
- **If your PR supersedes another**, close the old one with a link to yours.

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
- **No Cilium L7 proxy on this cluster** — never put an L7 `rules: dns:` block in a `CiliumNetworkPolicy`. It makes the WHOLE policy `Valid=False` and **silently unenforced** (egress isolation gone). Use L4-only DNS (port 53 → kube-dns) + IP `toCIDR`. (Bit `media/qbittorrent` + `monitoring/alloy-jeeves` — unenforced for months before it was caught.)
- **A new app behind `authentik-forward-auth`** needs more than the ingress middleware: also add an `app-<name>` blueprint **and** its provider binding in `embedded-outpost.yaml` under `cluster/apps/authentik/resources/`, or the host 404s with Authentik "Not Found". Use the existing `app-*.yaml` as templates.

## Handing work to Jeeves (autonomous maintenance)

[Jeeves](https://github.com/Arsenikki/jeeves) is the in-cluster bot that turns a
**ticket** into a PR: it plans the ticket, codes it in an isolated worktree, runs
the quality gate, and opens a PR. Use it to hand off maintenance instead of doing
it by hand.

**Hand-off is via the `flock` ticketing app** — a self-built ticket system
(repo: [Arsenikki/flock](https://github.com/Arsenikki/flock)) that exposes an API
for creating tickets. File **one ticket per deliverable** there; Jeeves ingests
tickets from flock.

> **Do NOT file GitHub issues for Jeeves.** The old GitHub-issue + `jeeves`-label
> trigger is retired. The exact flock ticket API (endpoint, auth, payload) isn't
> pinned down here yet — confirm the current method before filing, and refine this
> section as it settles.

**Write the ticket for an agent, not a human.** A vague ticket stalls on a
clarifying question. Give it:
- the desired **end state and acceptance criteria**, not just the symptom;
- the **files/paths** to change (e.g. `cluster/apps/<ns>/…`, `infra/terraform/…`, `infra/talos/…`);
- the repo rules that apply — sops-encrypted secrets, pin versions (never `latest`),
  and **don't hand-fix ArgoCD drift, commit it** (see Gotchas). Keep each ticket to one PR's worth.

**Merges are gated, not blind:** Jeeves opens the PR, but anything touching
`cluster/**` (ArgoCD self-heals on merge) or any higher-risk / behavioral change is
left for **you to review and merge on GitHub**. Low-risk, non-behavioral changes
outside `cluster/**` may auto-merge once the gate is green (`prek` hooks + required
checks `yaml` + `Render ArgoCD diff` + `yamllint ./cluster/`).
