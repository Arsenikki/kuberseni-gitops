# resepti

Self-hosted recipe manager — Go API + embedded Preact PWA, with AI recipe import
and a hands-free cooking assistant powered by a self-hosted Paseo + Claude agent
(the coachi pattern). Served at **https://resepti.arsenikki.casa** behind
Authentik forward-auth.

## Components

| Workload            | Kind        | What it does                                             |
|---------------------|-------------|---------------------------------------------------------|
| `resepti-postgres`  | StatefulSet | Postgres 16 (Longhorn PVC)                               |
| `resepti-api`       | Deployment  | API + embedded PWA; drives the Paseo daemon             |
| `resepti-mcp`       | Deployment  | resepti MCP server the agents call (read/write cookbook)|

Images: `ghcr.io/arsenikki/resepti` (API+MCP).

## One-time setup

1. **1Password** — nothing to create; every secret is reused from existing items:
   Postgres ← **`coachi`**/postgres_password, Claude ← **`Jeeves Agent`**/claude_code_oauth_token,
   GHCR pull ← **`github-packages-ro`**, S3 ← **`seaweedfs-s3`**.
   ⚠️ Postgres is shared with coachi's DB password by request — if that item is
   rotated, update resepti's secret + DB together.

2. **SeaweedFS bucket** — the app auto-creates `resepti-media` on first start if
   the S3 creds allow it; otherwise create it once.

3. **Authentik** — the ingress references `authentik-forward-auth@kubernetescrd`.
   No app config needed; add the host to an Authentik application/provider if you
   want per-app authorization policies.

## Deploy

Commit `cluster/apps/resepti/*` and `cluster/argocd/apps/resepti.yaml`; the
ArgoCD root-app discovers the new Application and syncs it. Then:

```
kubectl -n resepti get pods
kubectl -n argocd get application resepti
```

## Releasing a new version

Tag `vX.Y.Z` in the resepti repo (CI builds + pushes both images), then bump the
`0.1.0` tags in `api.yaml`, `mcp.yaml`, `paseo.yaml` to `X.Y.Z` and merge.
⚠️ Gate the image-bump merge on CI-green or the paseo StatefulSet will
ImagePullBackOff (same lesson as coachi).
