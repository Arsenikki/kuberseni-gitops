# abs-opds

ArgoCD-managed [abs-opds](https://github.com/Vito0912/abs-opds) — re-serves the
Audiobookshelf ebook library as an **OPDS feed** so KOReader (on the jailbroken
Kindle) can **browse and download EPUBs directly over WiFi**. ABS itself has no
native OPDS; this bridge fills that gap. Namespace `media`, sync-wave `6`. The
ArgoCD `Application` lives at `cluster/argocd/apps/media-abs-opds.yaml`.

## What this deploys

| File | Resource |
| --- | --- |
| `values.yaml` | `app-template` release: Deployment (`ghcr.io/vito0912/abs-opds:2.0.5`, stateless, no PVC) + ClusterIP Service (3010) + Traefik Ingress `abs-opds.arsenikki.casa` (cert-manager TLS, **no** forward-auth) |

No PVC and no ExternalSecret — the bridge is stateless (in-memory caches only)
and authenticates to ABS per-request (see below).

## How it reaches ABS

`ABS_URL=http://audiobookshelf.media.svc.cluster.local` (in-cluster Service, port
80, no trailing slash, no `/api`). `USE_PROXY=true` routes cover thumbnails
through the bridge so the Kindle never needs ABS's internal URL.
`SHOW_AUDIOBOOKS=false` keeps the catalog EPUB-only.

## Auth model

The bridge uses **auto-login**: whatever username/password KOReader sends, it
forwards to ABS `/login`, gets that user's token, and serves only what that ABS
user can see. So there is **no stored ABS token / secret** — your ABS
credentials live only in the KOReader URL on the device.

## KOReader setup (on the Kindle)

KOReader → **OPDS catalog** → add:

```
https://<abs-username>:<abs-password>@abs-opds.arsenikki.casa/opds
```

- Embed the credentials in the URL and **leave KOReader's username/password
  fields blank** — KOReader's Basic-auth form is unreliable, so userinfo-in-URL
  is the supported method.
- Path is `/opds` with **no trailing slash**.
- HTTPS is required (credentials ride in the URL) — the ingress terminates TLS.

Then browse your library and tap a book to download the EPUB straight to the
device. (Progress sync is separate — that's BookBridge's kosync; see
`../bookbridge/README.md`.)

## Gotchas

- **Image tag has no leading `v`**: pin `:2.0.5`, not `:v2.0.5` (the latter 404s
  on GHCR even though the git tag is `v2.0.5`).
- If auto-login ever misbehaves, the alternative is the `OPDS_USERS` env
  (`username:ABS_API_TOKEN:password`, comma-separated) with a pre-generated ABS
  API token — would need an ExternalSecret; not used here.

## Sync

GitOps: merging to `main` auto-syncs via ArgoCD. Don't `kubectl apply`.
