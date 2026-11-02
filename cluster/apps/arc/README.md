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

Scale sets: `arc-jeeves`, `arc-paseo-homelab`, `arc-resepti`,
`arc-coachi`, `arc-captain-core`. A workflow job targets one with
`runs-on: arc-<repo>`.

## How a job runs

A listener pod per scale set (in `arc-systems`) long-polls GitHub. When a job is
queued, the controller creates one runner pod in `arc-runners` on the dedicated CI
node (see [Isolation](#isolation)), the job runs, and the pod is deleted. Nothing
runs while CI is idle (`minRunners: 0`).

Each runner pod = the `runner` container (`ghcr.io/actions/actions-runner`, minimal
Ubuntu 24.04: git, curl, jq, unzip, sudo, docker CLI + buildx — **no** gh, make,
gcc, compose, node on PATH) + a privileged `dind` sidecar (`docker:<ver>-dind`).
Every pod starts empty: tool downloads (setup-go/node, mise) and image pulls happen
each job; the `type=gha` build cache is the warm path.

## Isolation

The dind sidecar must be **privileged** (rootful dockerd), and the runner can talk
to it, so **any job can become root on the node it runs on** (`docker run
--privileged -v /dev:/dev ...`) — read the node's disks (Longhorn replicas),
kubelet credentials and other pods' secrets, and bypass Cilium policy. The jobs run
PR code written by Jeeves' agents and every npm/Go dependency and third-party
action they pull, so treat them as untrusted. NetworkPolicy, ephemeral pods and
private-only repos limit ordinary mistakes; they do **not** contain a privileged
job.

So runner pods only schedule on a node labelled `kuberseni.io/arc-runner=true` and
tainted `kuberseni.io/arc-runner=true:NoSchedule` (`runners/values.yaml`). **Until
such a node exists they stay Pending** — fail-safe: never next to 1Password Connect,
ArgoCD, authentik or Longhorn data on worker-01/02. Ways to provide it:

| Option | Containment | Cost |
|---|---|---|
| Dedicated Talos worker VM (e.g. `ci-01`, 4 vCPU / 8 GiB / 80 GB, no Longhorn disk), labelled + tainted in `infra/talos/talconfig.yaml` | Escape = root on a node that runs only CI and the node DaemonSets (Cilium, monitoring); still on the LAN | RAM: every Proxmox host is ~full (minipc 29.9/31 GiB, nas 30/31, router 14/15) — needs a RAM upgrade or freeing a VM |
| Kata Containers `RuntimeClass` (siderolabs `kata-containers` extension) on an existing worker, pods with `runtimeClassName: kata` | Each runner pod is its own micro-VM: privileged dind is root only inside it | Talos extension + reboot of that worker; nested virtualisation on the Proxmox host (VMs already use `cpu: host`); per-pod VM overhead |
| Both (dedicated node running Kata) | Best | Both |

Do **not** run `infra/scripts/arc-switch-workflows.sh` before one of these exists —
until then jobs would just wait for a runner that can't schedule.

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
   above — the helper checks this via the GitHub API and refuses (reload after
   fixing) an "All repositories" install or a different repo set: the key is
   repo-admin on whatever the installation covers. If the browser doesn't come back
   after installing, open http://127.0.0.1:8971/installed.

   The helper writes `github_app_id`, `github_app_private_key` and
   `github_app_installation_id` into the 1Password item `arc-github-app` (vault
   `homelab`). The key only touches disk as a 0600 temp file it deletes — unless
   writing to 1Password fails, in which case it saves it to
   `~/<slug>.<id>.private-key.pem` (the manifest code is single-use) and tells you
   to move it into 1Password and delete the file. GitHub has no API to create an
   App outright — the manifest flow needs that one click.

2. **Merge this PR.** ArgoCD syncs `arc-controller` (wave 5) then `arc-runners`
   (wave 6). Check: `kubectl -n arc-systems get pods` shows the controller and six
   `arc-<repo>-…-listener` pods; each repo's Settings → Actions → Runners lists its
   `arc-<repo>` scale set. Safe before the CI node exists: no job is routed to
   these runners until step 4.

3. **Provide the isolated CI node** (see [Isolation](#isolation)).

4. **Switch the workflows** (needs `gh` with the `workflow` scope:
   `gh auth refresh -s workflow`):

   ```sh
   infra/scripts/arc-switch-workflows.sh --dry-run   # review
   infra/scripts/arc-switch-workflows.sh             # one PR per repo
   ```

   Re-running is safe: repos that already have the `ci/arc-runners` branch are
   skipped.

5. **Validate the egress policy** — see the CAVEATS block in
   `runners/networkpolicy.yaml`.

## Maintenance

- **Version lockstep.** Both charts (`gha-runner-scale-set-controller` in
  `arc-controller.yaml`, `gha-runner-scale-set` ×6 in `arc-runners.yaml`) must be
  on the same version — the controller deletes scale sets whose major.minor
  differs. Renovate groups them (`group/arc`).
- **Runner image freshness.** GitHub stops sending jobs to self-hosted runners that
  are more than ~30 days behind a runner release (the scale set then shows phase
  `Outdated`, which is sticky until the runner spec/image changes). Merge the
  grouped Renovate PR (`group/arc`) promptly — and don't rely on it alone: as of
  2026-10 renovate-ce hasn't completed a kuberseni-gitops run in weeks (disk-space
  errors). Manual check: `gh release list -R actions/runner --limit 1`; if newer than
  the pinned tag, bump both `ghcr.io/actions/actions-runner:<ver>` lines in
  `runners/values.yaml` in one PR.
- **MTU.** dockerd runs with `--mtu=1370` because pod traffic here is Cilium VXLAN
  + WireGuard (default route `mtu 1370`). If Cilium's tunnel/encryption changes,
  re-measure with `ip route show default` in a pod and update `runners/values.yaml`.
- **Capacity.** Each runner pod requests 1 CPU / 1.5 GiB / 8 GiB ephemeral; size the
  CI node for ~2 concurrent pods. More just wait as Pending. `maxRunners` per repo
  is in `runners/repos/`.
- **Draining the CI node** kills in-flight jobs (no PDB for busy runners upstream):
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
| Runner pod Pending | no node labelled + tainted for CI yet (see Isolation), or its capacity (`kubectl describe pod`); PriorityClass `kuberseni-low` never preempts |
| Pulls/TLS hang inside builds | MTU (above); `docker network inspect bridge` in the dind container should show 1370 |
| Docker Hub `toomanyrequests` | anonymous limit (100 pulls / 6 h per NAT IP); dockerd uses `mirror.gcr.io`, BuildKit base-image pulls don't — add a Docker Hub login to the workflow |
| Scale set phase `Outdated` | bump the runner image (Renovate) |
