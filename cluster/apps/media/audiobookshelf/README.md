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
**`books`** subfolder (`subPath: books`) and mounted **read-only**. Audiobookshelf
therefore cannot see or modify `movies/series/music/downloads` — only `books`.
Populate `<nfs>/books/...` via Readarr or your own drops; ABS just serves it.
Reading progress, bookmarks and cached art live in `/config` + `/metadata`, so a
read-only library is fully functional.

## Auth (important)

**Do not** put Authentik forward-auth in front of ABS — it breaks the mobile
apps, OPDS and the BookBridge/API clients (they can't complete the browser login;
the app polls `/ping`, gets a 302, and shows an empty shelf). Use ABS's own
built-in accounts. If you want SSO later, wire Authentik as an **OIDC provider**
(Settings → Authentication → OpenID Connect), which keeps the apps working.

## Post-deploy setup

1. Open `https://audiobookshelf.arsenikki.casa`, create the root/admin user.
2. Add libraries pointing at the read-only paths, e.g. `/data/audiobooks`
   (Books/Audiobook type) and `/data/ebooks`.
3. Create an **API token** (Settings → Users → your user → API token) — you'll
   paste it into BookBridge to let it read your listening position.
4. On the Kindle's KOReader, add ABS as an **OPDS catalog**:
   `https://audiobookshelf.arsenikki.casa/opds` with your ABS username +
   password (or API key) to browse/download EPUBs. Reading-position sync is
   handled by **BookBridge**, not ABS — see `../bookbridge/README.md`.

## Sync

GitOps: merging to `main` auto-syncs via ArgoCD (`prune`, `selfHeal`,
`CreateNamespace=true`). Don't `kubectl apply`. To pause, set
`spec.syncPolicy.automated.selfHeal: false` on the Application.
