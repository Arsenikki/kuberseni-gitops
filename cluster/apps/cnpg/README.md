# cnpg — CloudNativePG platform (Phase 0)

Shared Postgres platform for the cluster. This directory is **Phase 0 only**: the
operator, the Barman Cloud backup plugin, and a dedicated StorageClass. No databases
are migrated here — per-app `Cluster` resources live in each app's own directory
(e.g. `cluster/apps/coachi/cnpg-cluster.yaml`).

## What's here

| File | Purpose |
|---|---|
| `operator/values.yaml` | CloudNativePG operator Helm values (chart `cloudnative-pg` 0.29.1 → operator **1.30.1**). |
| `operator/storageclass.yaml` | `longhorn-cnpg` StorageClass (1 Longhorn replica, strict-local — see file). |
| `plugin/values.yaml` | Barman Cloud Plugin Helm values (chart `plugin-barman-cloud` 0.8.1 → **v0.15.1**). |

ArgoCD apps: `cluster/argocd/apps/cnpg-operator.yaml` (wave 1) and
`cluster/argocd/apps/cnpg-barman-plugin.yaml` (wave 2). The Helm repo
`https://cloudnative-pg.github.io/charts` is added to the `kuberseni` AppProject.

## Why plugin-only (not in-tree barmanObjectStore)

In-tree `spec.backup.barmanObjectStore` is deprecated since operator 1.26 and is
**removed in 1.31**. Starting plugin-only avoids a forced migration later.

## ⚠️ SeaweedFS requires a checksum workaround

SeaweedFS is not an officially supported Barman backend. boto3 ≥1.36 sends CRC32
checksums older S3-compatible backends reject (`barman-cloud-wal-archive: exit 4`,
plugin issue #679). Every per-app `ObjectStore` therefore sets, in
`spec.instanceSidecarConfiguration.env`:

```yaml
- { name: AWS_REQUEST_CHECKSUM_CALCULATION, value: when_required }
- { name: AWS_RESPONSE_CHECKSUM_VALIDATION, value: when_required }
```

Our SeaweedFS (Helm chart 4.34.0 ≈ server 4.34) is ≥ 3.85, so the fix applies — but
**prove a real backup + PITR restore (see each app's RUNBOOK) before trusting it.**

## Validate after Phase 0 syncs

```sh
kubectl -n cnpg-system get pods                 # operator + barman-cloud Running
kubectl get crd | grep cnpg                     # clusters, poolers, objectstores...
kubectl get storageclass longhorn-cnpg
```

No `Cluster` exists yet — Phase 1 (coachi) migrates the first database.
