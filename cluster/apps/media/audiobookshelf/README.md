# audiobookshelf

ArgoCD-managed [Audiobookshelf](https://www.audiobookshelf.org/) — self-hosted
audiobook + ebook server (namespace `media`, sync-wave `5`). The ArgoCD
`Application` lives at `cluster/argocd/apps/media-audiobookshelf.yaml` and renders
the bjw-s `app-template` chart with `values.yaml`.

## What this deploys

| File | Resource |
| --- | --- |
| `values.yaml` | `app-template` release: Deployment (`ghcr.io/advplyr/audiobookshelf:2.36.0`, 1 replica, `Recreate`) + ClusterIP Service (80) + Traefik Ingress `audiobookshelf.arsenikki.casa` (cert-manager TLS, **no** forward-auth) |
| `pvc.yaml` | Longhorn PVCs `audiobookshelf-config` (5Gi, SQLite DB) + `audiobookshelf-metadata` (20Gi, covers/backups) |

## Storage scoping

The library mount is the shared **`media-pvc`** but restricted to the existing
**`books`** subfolder (`subPath: books`), so Audiobookshelf cannot see or touch
`movies/series/music/downloads` — only `books`. The mount is **read-write**: ABS's
ebook-upload feature creates item folders in the library, and a read-only mount
made a failed upload crash the whole process (see PR #679). Writes stay confined
to the `books` subfolder. Populate `<nfs>/books/...` via the ABS web UI, Readarr,
or your own drops.

## Auth (important)

**Do not** put Authentik forward-auth in front of ABS — it breaks the mobile
apps and the BookBridge/API clients (they can't complete the browser login;
the app polls `/ping`, gets a 302, and shows an empty shelf). Use ABS's own
built-in accounts. If you want SSO later, wire Authentik as an **OIDC provider**
(Settings → Authentication → OpenID Connect), which keeps the apps working.

## Post-deploy setup

1. Open `https://audiobookshelf.arsenikki.casa`, create the root/admin user.
2. Add libraries pointing at e.g. `/data/audiobooks` (Audiobook type) and
   `/data/ebooks` (Book type). Uploading ebooks via the web UI works — the mount
   is read-write.
3. Create an **API token** (Settings → Users → your user → API token) — you'll
   paste it into BookBridge to let it read your listening position.
4. **Reading on the Kindle is NOT via ABS** — ABS has no native OPDS feed
   (`/opds` 404s). Ebook browse/download to KOReader is served by the separate
   **abs-opds** bridge (`../abs-opds/README.md`), and reading-position sync by
   **BookBridge** (`../bookbridge/README.md`).

## Sync

GitOps: merging to `main` auto-syncs via ArgoCD (`prune`, `selfHeal`,
`CreateNamespace=true`). Don't `kubectl apply`. To pause, set
`spec.syncPolicy.automated.selfHeal: false` on the Application.
