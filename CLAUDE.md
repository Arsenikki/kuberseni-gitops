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
- **No Cilium L7 proxy on this cluster** — never put an L7 `rules: dns:` block in a `CiliumNetworkPolicy`. It makes the WHOLE policy `Valid=False` and **silently unenforced** (egress isolation gone). Use L4-only DNS (port 53 → kube-dns) + IP `toCIDR`. (Bit `media/qbittorrent` + `monitoring/alloy-jeeves` — unenforced for months before it was caught.)
- **A new app behind `authentik-forward-auth`** needs more than the ingress middleware: also add an `app-<name>` blueprint **and** its provider binding in `embedded-outpost.yaml` under `cluster/apps/authentik/resources/`, or the host 404s with Authentik "Not Found". Use the existing `app-*.yaml` as templates.

## Handing work to Jeeves (autonomous maintenance)

[Jeeves](https://github.com/Arsenikki/jeeves) is the in-cluster bot that turns a
GitHub issue into a PR: it plans the ticket, codes it in an isolated worktree,
runs the quality gate, and opens a PR — steered entirely from **GitHub labels +
Telegram**. This repo is **registered and eligible**, so tickets filed here get
worked automatically. Use this to hand off maintenance instead of doing it by hand.

**File one issue per deliverable, labelled `jeeves`.** That label is the *only*
trigger: an open issue carrying it (and no `agent/*` label yet) is claimed by the
prod instance — picked up within ~5 min (issue poll), or seconds if the GitHub
webhook is wired. To hand off several pieces of work (X, Y, Z), file several issues.

```bash
# one-time: create the trigger label if it doesn't exist yet
gh label create jeeves -R Arsenikki/kuberseni-gitops \
  -c 5319e7 -d 'Jeeves: autonomously plan, code and PR this ticket' 2>/dev/null || true

gh issue create -R Arsenikki/kuberseni-gitops --label jeeves \
  --title '<imperative, single-PR-sized summary>' \
  --body  '<desired end state + acceptance criteria + paths to touch + constraints>'
```

**Write the body for an agent, not a human.** Planning batches *all* its questions
up front, then either proceeds or parks the ticket in `agent/needs-decision` (and
pings Telegram) until you answer — so a vague ticket stalls. Give it:
- the desired **end state and acceptance criteria**, not just the symptom;
- the **files/paths** to change (e.g. `cluster/apps/<ns>/…`, `infra/tofu/…`, `infra/talos/…`);
- the repo rules that apply — sops-encrypted secrets, pin versions (never `latest`),
  and **don't hand-fix ArgoCD drift, commit it** (see Gotchas). Keep each issue to one PR's worth.

**Route (optional):** add `jeeves-instance/dev` to send a ticket to the dev/candidate
instance instead; a bare `jeeves` label goes to prod.

**Track it** via the labels Jeeves stamps on the issue:
`agent/planning` → (`agent/needs-decision`) → `agent/in-progress` → `agent/pr-open` → `agent/done`.
Don't set `agent/*` yourself — they're Jeeves-owned, and an issue that already carries
one won't be re-ingested.

**Merges are gated, not blind:**
- Changes **outside `cluster/**`** auto-merge once the gate is green (`prek` hooks +
  required checks `yaml` and `Render ArgoCD diff` + `yamllint ./cluster/`) — but only
  when low-risk and non-behavioral.
- Anything **touching `cluster/**`** (ArgoCD self-heals on merge), or any higher-risk /
  behavioral change, is left for **you to review and merge on GitHub**. Add `human/hold`
  to the issue to freeze auto-merge.
