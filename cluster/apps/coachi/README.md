# coachi

Personal fitness coaching / workout & health tracking app. Log workouts, track
progress (e1RM, calisthenics hold PRs, pace/volume trends), and get AI coaching
— interactive and scheduled — with **Paseo as the single surface to Claude + MCP**.

Source: <https://github.com/Arsenikki/coachi> (Go API + embedded React PWA).

## Components (namespace `coachi`)

| Workload           | Kind        | Role |
|--------------------|-------------|------|
| `coachi-postgres`  | StatefulSet | Postgres 16 (workouts, health, coaching, conversations). Longhorn PVC. |
| `coachi-mcp`       | Deployment  | coachi MCP server — agents read workouts/progress + `save_feedback`/`save_health_snapshot`. |
| `coachi-paseo`     | StatefulSet | Self-hosted Paseo daemon running the Claude coaching agents (image `coachi-paseo`, workspace baked in). Longhorn PVC for `/data/paseo`. |
| `coachi-api`       | Deployment  | API + PWA. Drives the daemon over TCP `coachi-paseo:6767`; runs the scheduler (daily readiness / weekly review → Telegram). Fronted by the ingress. |

```
PWA ──▶ coachi-api ──drives──▶ coachi-paseo (Claude agents)
              │                     ├─ freddy MCP  (Apple Health, read-only)
              └─ Postgres           └─ coachi MCP (coachi-mcp: workouts read + writes)
```

The API and daemon are mutually reachable in-cluster: the API dials
`coachi-paseo:6767`; the agents on the daemon call `http://coachi-mcp:9090`
(from `COACHI_MCP_URL`) and `https://freddy.coach/mcp/$FREDDY_TOKEN`.

## Secrets — 1Password item `coachi` (vault `homelab`)

`externalsecret.yaml` pulls these fields into the `coachi-secrets` k8s secret via
the `onepassword` ClusterSecretStore. **Create the item before first sync:**

| Field | Purpose |
|-------|---------|
| `postgres_password`       | DB password (db + api + mcp). |
| `claude_code_oauth_token` | Claude credential for the agents — **same one jeeves uses**; copy it. |
| `freddy_token`            | Permanent Freddy token (the `/mcp/<token>` tail from freddy.coach). Empty ⇒ no Apple Health. |
| `telegram_bot_token`      | BotFather token for scheduled-coaching delivery. **Rotate the previously-leaked token.** Empty ⇒ no Telegram. |
| `telegram_chat_id`        | Target chat/group id. |

## Images (GHCR, built by coachi CI)

- `ghcr.io/arsenikki/coachi:<tag>`       — API + MCP (one binary, `serve`/`mcp` commands).
- `ghcr.io/arsenikki/coachi-paseo:<tag>` — Paseo daemon + baked coaching-workspace.

Tags are pinned inline in `mcp.yaml` / `api.yaml` / `paseo.yaml` (never `latest`).
Bump them here on release. The coachi repo's GitHub Actions workflow builds and
pushes both images on tag.

The packages are **private**; the cluster pulls them via the `ghcr-credentials`
image-pull secret (`ghcr-secret.yaml` — a dockerconfigjson ESO renders from the
1Password `coachi` item fields `ghcr_username` + `ghcr_pat`, a `read:packages`
PAT), referenced by `imagePullSecrets` on the mcp/paseo/api workloads (same
pattern as captain-core). No need to make the GHCR packages public.

## Security — internet exposure

`ingress.yaml` is **internal by default** (`external-dns/is-public: "false"`) —
this app holds personal health data. Before exposing it publicly, add auth
(authentik forward-auth middleware — commented in the ingress — or Tailscale
ingress). Don't ship it unauthenticated.

## Deploy

1. Create the `coachi` 1Password item (above).
2. Ensure CI has published the two images at the tags pinned here.
3. Merge this directory + `cluster/argocd/apps/coachi.yaml` to `main` (PR only).
   ArgoCD syncs; `CreateNamespace=true`.
4. Verify: `kubectl -n coachi get pods` all Ready; open `https://coachi.arsenikki.casa`
   (from LAN/Tailscale); log a set; ask the coach; check a scheduled run lands in Telegram.

> ArgoCD self-heals — don't hand-fix drift, commit it (see repo CLAUDE.md).
