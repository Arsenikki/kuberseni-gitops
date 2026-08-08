# untappi-go

ArgoCD-managed deployment of the **untappi-go** app (namespace `untappi-go`,
sync-wave `5`). The ArgoCD `Application` lives at
`cluster/argocd/apps/untappi-go.yaml`.

## What this deploys

| File | Resource |
| --- | --- |
| `namespace.yaml` | Namespace `untappi-go` |
| `externalsecret.yaml` | `ExternalSecret` -> secret `untappi-go-secrets` (Untappd creds + Postgres password) via the `onepassword` ClusterSecretStore |
| `configmap.yaml` | `untappi-go-config` (NATS URL, Untappd base URL + hourly budget, HTTP addr) |
| `postgres.yaml` | StatefulSet `untappi-postgres` (postgis/postgis:16-3.4, Longhorn 10Gi) + headless Service on 5432 |
| `nats.yaml` | StatefulSet `nats` (nats:2.10-alpine, JetStream, Longhorn 5Gi) + Service (4222 client / 8222 monitor) |
| `api.yaml` | Deployment `untappi-go-api` (`/untappi api`, 2 replicas) + ClusterIP Service (80 -> 8080) |
| `worker.yaml` | Deployment `untappi-go-worker` (`/untappi worker`, 1 replica, `Recreate`) |
| `ingress.yaml` | Traefik Ingress `untappi.arsenikki.casa` (cert-manager `letsencrypt-prod`, external-dns public) |

## Manual prerequisites (before syncing)

1. **Create the `untappi-go` 1Password item** in the **homelab** vault with a
   `postgres_password` field. This item does not exist yet and the
   `ExternalSecret` (hence Postgres, api, worker and the migrate job) will not
   populate without it.
2. Confirm the **`untappd-api-creds`** 1Password item (homelab vault) exists with
   `client_id` and `client_secret` fields.
3. **Make `ghcr.io/arsenikki/untappi-go` a public package** (assumed public — no
   `imagePullSecret` is configured). If it must stay private, add a
   `dockerconfigjson` ExternalSecret + `imagePullSecrets` to the api / worker /

## Sync

This is GitOps: **pushing these files to `main` auto-syncs via ArgoCD** (app-of-apps,
`prune: true`, `selfHeal: true`, `CreateNamespace=true`). Do not `kubectl apply`
manually. To pause auto-sync, set `spec.syncPolicy.automated.selfHeal: false` on
the Application.
