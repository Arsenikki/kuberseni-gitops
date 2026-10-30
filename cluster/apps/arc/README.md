# ARC — self-hosted GitHub Actions runners

[Actions Runner Controller](https://github.com/actions/actions-runner-controller)
(the `gha-runner-scale-set` flavour) runs ephemeral GitHub Actions runners in this
cluster for the **private** repos, so their CI doesn't depend on (paid,
quota-limited) GitHub-hosted minutes. Public repos keep the free hosted runners and
must **never** get a self-hosted runner (fork PRs would run in the homelab).

| Piece | Where |
|---|---|
| Controller + CRDs (`arc-systems`), runner namespace | `cluster/argocd/apps/arc-controller.yaml`, `controller/` |
| One scale set per repo (`arc-runners`), GitHub App secret, egress policy | `cluster/argocd/apps/arc-runners.yaml`, `runners/` |
| Shared runner pod (dind, MTU, resources, node) | `runners/values.yaml` |
| Per-repo scale set (`githubConfigUrl`, `runnerScaleSetName`, `maxRunners`) | `runners/repos/<repo>.yaml` |
| GitHub App creation helper | `infra/scripts/arc-github-app/` |
| Workflow switch (`runs-on: arc-<repo>`) | `infra/scripts/arc-switch-workflows.sh` |

Scale sets: `arc-jeeves`, `arc-paseo-homelab`, `arc-resepti`, `arc-flock`,
`arc-coachi`, `arc-captain-core`. A workflow job targets one with
`runs-on: arc-<repo>`.

## How a job runs

A listener pod per scale set (in `arc-systems`) long-polls GitHub. When a job is
queued, the controller creates one runner pod in `arc-runners` on **worker-01**
(the only node with room for builds), the job runs, and the pod is deleted. Nothing
runs while CI is idle (`minRunners: 0`).

Each runner pod = the `runner` container (`ghcr.io/actions/actions-runner`, minimal
Ubuntu 24.04: git, curl, jq, unzip, sudo, docker CLI + buildx — **no** gh, make,
gcc, compose, node on PATH) + a privileged `dind` sidecar (`docker:<ver>-dind`).
Every pod starts empty: tool downloads (setup-go/node, mise) and image pulls happen
each job; the `type=gha` build cache is the warm path.

## Setup (once)

1. **Create the GitHub App + 1Password item** (on a machine with a browser and the
   `op` CLI signed in):

   ```sh
   cd infra/scripts/arc-github-app && mise exec go@1.26.4 -- go run .
   ```

   It opens GitHub with a pre-filled, private App (no webhook; Repository
   permissions **Administration: read & write** + **Metadata: read** — what
   repo-level runner registration needs). Click **Create GitHub App**, then on the
   install page choose **Only select repositories** and pick exactly the six repos
   above. The helper writes `github_app_id`, `github_app_private_key` and
   `github_app_installation_id` into the 1Password item `arc-github-app` (vault
   `homelab`); the key never touches disk except a 0600 temp file it deletes.
   GitHub has no API to create an App outright — the manifest flow needs that one
   click.

2. **Merge this PR.** ArgoCD syncs `arc-controller` (wave 5) then `arc-runners`
   (wave 6). Check: `kubectl -n arc-systems get pods` shows the controller and six
   `arc-<repo>-…-listener` pods; each repo's Settings → Actions → Runners lists its
   `arc-<repo>` scale set.

3. **Switch the workflows** (needs `gh` with the `workflow` scope:
   `gh auth refresh -s workflow`):

   ```sh
   infra/scripts/arc-switch-workflows.sh --dry-run   # review
   infra/scripts/arc-switch-workflows.sh             # one PR per repo
   ```

4. **Validate the egress policy** — see the CAVEATS block in
   `runners/networkpolicy.yaml`.

## Maintenance

- **Version lockstep.** Both charts (`gha-runner-scale-set-controller` in
  `arc-controller.yaml`, `gha-runner-scale-set` ×6 in `arc-runners.yaml`) must be
  on the same version — the controller deletes scale sets whose major.minor
  differs. Renovate groups them (`group/arc`).
- **Runner image freshness.** GitHub stops sending jobs to self-hosted runners that
  are more than ~30 days behind a runner release (the scale set then shows phase
  `Outdated`). Merge the grouped Renovate PR for `ghcr.io/actions/actions-runner`
  promptly.
- **MTU.** dockerd runs with `--mtu=1370` because pod traffic here is Cilium VXLAN
  + WireGuard (default route `mtu 1370`). If Cilium's tunnel/encryption changes,
  re-measure with `ip route show default` in a pod and update `runners/values.yaml`.
- **Capacity.** worker-01 has room for ~2 concurrent runner pods (1 CPU / 1.5 GiB /
  8 GiB ephemeral requested each); more just wait as Pending. `maxRunners` per repo
  is in `runners/repos/`.
- **Draining worker-01** kills in-flight jobs (no PDB for busy runners upstream):
  drain when CI is idle.
- **Removal order:** delete `arc-runners` before `arc-controller` (the controller
  removes the cleanup finalizers on the scale sets' Roles/ServiceAccounts).
- **Adding a repo:** add it to the App installation (GitHub → Settings →
  Applications → the ARC App → Configure), add `runners/repos/<repo>.yaml` and a
  source block in `arc-runners.yaml`, then point its workflows at `arc-<repo>`.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Job stays "Waiting for a runner" | `kubectl -n arc-systems logs deploy/arc-gha-rs-controller`; listener pod for that repo; `kubectl -n arc-runners get autoscalingrunnersets,ephemeralrunners` |
| No listener pods | `kubectl -n arc-runners get externalsecret arc-github-app` (SecretSyncedError = 1Password item/fields missing) |
| Runner pod Pending | worker-01 capacity (`kubectl describe pod`); PriorityClass `kuberseni-low` never preempts |
| Pulls/TLS hang inside builds | MTU (above); `docker network inspect bridge` in the dind container should show 1370 |
| Docker Hub `toomanyrequests` | anonymous limit (100 pulls / 6 h per NAT IP); dockerd uses `mirror.gcr.io`, BuildKit base-image pulls don't — add a Docker Hub login to the workflow |
| Scale set phase `Outdated` | bump the runner image (Renovate) |
