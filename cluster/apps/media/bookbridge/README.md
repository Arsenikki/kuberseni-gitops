# bookbridge

ArgoCD-managed [BookBridge](https://github.com/cporcellijr/bookbridge) — the
Audiobookshelf ⇄ KOReader **audio↔text position bridge** (namespace `media`,
sync-wave `6`, after audiobookshelf). It also **is** the KOReader `kosync` server,
so no separate kosync server is deployed. The ArgoCD `Application` lives at
`cluster/argocd/apps/media-bookbridge.yaml`.

## What this does

You listen to an audiobook in the ABS app; you pick up the Kindle and KOReader
opens the EPUB at roughly the spot you stopped — and vice versa. BookBridge polls
ABS for your listening position, force-aligns audio to the EPUB text (built-in
Whisper `tiny` on CPU — no GPU), and reconciles it with KOReader's reading
position through its built-in kosync endpoint.

## What this deploys

| File | Resource |
| --- | --- |
| `values.yaml` | `app-template` release: Deployment (`ghcr.io/cporcellijr/bookbridge:v7.6.0`, 1 replica, `Recreate`) + Service (5757, dashboard + kosync) + Traefik Ingress `bookbridge.arsenikki.casa` (cert-manager TLS, **no** forward-auth) |
| `pvc.yaml` | Longhorn PVC `bookbridge-data` (15Gi) — SQLite DB, `secret.key`, transcripts, audio_cache. **Longhorn, not NFS** (SQLite locking) |
| `externalsecret.yaml` | `ExternalSecret` → secret `bookbridge-secret` (`BOOKBRIDGE_SECRET_KEY`) via the `onepassword` ClusterSecretStore |

The EPUB library is the shared `media-pvc` scoped to `subPath: books`,
**read-only** — same isolation as ABS.

## Manual prerequisites (before syncing)

1. **Create the `BookBridge` 1Password item** (vault **homelab**) with a
   `secret_key` field set to a long random string (`openssl rand -hex 32`). This
   encrypts the stored ABS token + KOReader passwords. The pod tolerates its
   absence (`optional: true`, falls back to an auto-generated `/data/secret.key`),
   but setting it means a `/data` restore won't lose stored credentials. Back it
   up together with the `bookbridge-data` PVC.

## Post-deploy setup

1. Open `https://bookbridge.arsenikki.casa`, create the admin login.
2. **Connect Audiobookshelf**: server URL `http://audiobookshelf.media.svc.cluster.local`
   (in-cluster) or `https://audiobookshelf.arsenikki.casa`, plus the ABS API
   token from step 3 of the ABS README, and pick the library.
3. **Create a KOReader/kosync user**: Account → My Integrations → KOReader/KoSync
   (username + password, has a Test button).
4. On the Kindle's KOReader: open a book → top menu → **Progress sync** →
   *Custom sync server* → `https://bookbridge.arsenikki.casa` → *Register / Login*
   with the credentials from step 3. Stock KOReader kosync needs **no plugin**
   for position sync (the optional "Bridge Sync" plugin only adds
   downloads/highlights).

> Auth note: KOReader's kosync client is non-interactive and can't pass an SSO
> login page, which is why this ingress has no forward-auth. BookBridge has its
> own admin login + per-user kosync creds. If you later want the dashboard behind
> Authentik, enable split-port mode (`KOSYNC_PORT=5758`) and expose only that
> path un-SSO'd.

## Sync

GitOps: merging to `main` auto-syncs via ArgoCD. Don't `kubectl apply`.
