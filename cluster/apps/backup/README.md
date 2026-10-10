# backup — offsite replication to Google Drive

Tier-2 of the backup strategy. **Tier 1** is the existing per-app `pg_dump →
SeaweedFS` CronJobs (hot, in-cluster, fast restore). This app adds **Tier 2**: a
single nightly `rclone copy` that pushes those SeaweedFS backups to **Google
Drive**, client-side encrypted, as a cold off-cluster copy that survives losing
the whole cluster.

```
pg_dump ─► SeaweedFS S3 (Tier 1) ─► rclone copy + crypt ─► Google Drive (Tier 2)
```

The job recursively mirrors the whole `coachi-media/backups/` prefix, so any app
that drops a dump there (coachi today; untappi / etcd-snapshot next) is replicated
offsite automatically — no change to this job is ever needed.

## Why this shape

- **Google Drive is not S3.** Nothing in the backup ecosystem speaks it natively;
  the only bridge is rclone. One job isolates every Drive foot-gun (750 GB/day
  upload cap, ~2 files/sec throttling, OAuth token churn) to one place.
- **`copy`, never `sync`** — a bad run can't delete offsite history.
- **Client-side `crypt`** — the pg_dumps (and, later, the etcd snapshot, which
  holds every cluster Secret in plaintext) are ciphertext before they reach
  Google. **Back up the crypt password + salt out-of-band** — lose them and the
  Drive copy is permanently unrecoverable.

## One-time setup (do this before the first run)

The CronJob reads a ready-made `rclone.conf` assembled by `externalsecret.yaml`
from the 1Password item **`rclone-gdrive`** (homelab vault). You populate that item
once, off-cluster. Do the OAuth dance on your laptop (there is no device flow
in-cluster).

### 1. Create your own Google OAuth client

rclone's shared client-id is being retired during 2026, so you need your own:

1. <https://console.cloud.google.com> → new project → **enable the Google Drive API**.
2. **OAuth consent screen** → User type **External** → fill the minimal fields →
   **PUBLISH / set to "In production"**. ⚠️ If you leave it in **Testing**, Drive
   refresh tokens expire after **7 days** and the CronJob dies silently after a
   week. (Re-mint the token *after* publishing — tokens minted while in Testing
   keep the 7-day cap.)
3. **Credentials** → Create credentials → **OAuth client ID** → type **Desktop
   app**. Note the **client_id** and **client_secret**.

> ⚠️ Do **not** use a service account. On a personal Google One account a
> standalone service account has **0 GB quota** and can't own files → every
> upload returns `403 storageQuotaExceeded`. A normal user OAuth token is the
> only path that lands bytes in your real quota.

### 2. Generate the token + obscured crypt passwords (on your laptop)

```sh
# Authorise the drive remote (opens a browser; produces a token JSON blob):
rclone config create gdrive drive \
  client_id <CLIENT_ID> client_secret <CLIENT_SECRET> scope drive
rclone config show gdrive        # copy the `token = {...}` value

# Pick a strong passphrase + salt, then obscure both:
rclone obscure 'your-crypt-passphrase'   # -> crypt_password
rclone obscure 'your-crypt-salt'         # -> crypt_password2
```

Store the passphrase + salt (plaintext) somewhere safe and separate — they are
the only way to decrypt the Drive copy.

### 3. Populate the 1Password item `rclone-gdrive` (homelab vault)

Fields (exact names — ESO maps them by `property`):

| field             | value                                                        |
|-------------------|-------------------------------------------------------------|
| `client_id`       | OAuth client id                                             |
| `client_secret`   | OAuth client secret                                         |
| `token`           | the `{...}` JSON from `rclone config show gdrive` (one line) |
| `crypt_password`  | output of `rclone obscure <passphrase>`                      |
| `crypt_password2` | output of `rclone obscure <salt>`                            |

The `seaweedfs-s3` item (access_key / secret_key) already exists and is reused for
the S3 source — nothing to do there.

### 4. Deploy & verify

ArgoCD picks up the new `backup` Application automatically. Then:

```sh
kubectl -n backup get externalsecret rclone-config          # SecretSynced=True
kubectl -n backup create job --from=cronjob/offsite-backup-gdrive manual-test
kubectl -n backup logs job/manual-test -f
```

## Operational notes

- **Retention:** `copy` accumulates on Drive forever (good — longer offsite
  retention than the 30-day SeaweedFS window). To cap it later, add a *guarded*
  `rclone delete --min-age 365d gdrive-crypt:coachi-media/backups` — never `sync`.
- **750 GB/day cap:** irrelevant at the current <1 GB/day volume;
  `--drive-stop-on-upload-limit` makes the job fail loudly if it's ever hit.
- **Hardening (optional):** switch `scope = drive` → `drive.file` in
  `externalsecret.yaml` so the token can only touch files rclone itself created
  (re-run the token dance in step 2 with `scope drive.file`). Smaller blast radius
  if the secret leaks.
- **This is not your DR backup of record.** A single Google account is a single
  point of failure, and Drive download throttling makes large restores
  unpredictable. When you want a backup you can *trust* for disaster recovery,
  repoint this same job at Backblaze B2 / Cloudflare R2 (true S3, ~$1/mo at this
  footprint) — it's a one-remote change.
