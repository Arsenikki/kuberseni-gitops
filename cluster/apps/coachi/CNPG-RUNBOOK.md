# coachi → CloudNativePG cutover runbook (Phase 1 pilot)

Migrates coachi off the bare `coachi-postgres` StatefulSet onto the CNPG `coachi-pg`
cluster, with WAL archiving + PITR to SeaweedFS (and onward to Google Drive via the
existing offsite job). **Offline migration** — plan a short maintenance window
(~5–15 min for coachi's ~5 Gi).

PRs involved (merge strictly in this order):
1. **#705** — Phase 0 (operator + plugin + StorageClass). Merge + verify Healthy first.
2. **this PR** (`cnpg-cluster.yaml`) — creates the cluster; **merging triggers the import**.
3. **the cutover PR** — repoints coachi-api/mcp/backup `coachi-postgres` → `coachi-pg-rw`. Merge only after Step 4 passes.

---

## 0. Pre-flight (no downtime)

```sh
kubectl -n cnpg-system get pods                       # operator + barman-cloud Running
kubectl get crd | grep -E 'clusters|objectstores'    # CRDs present
kubectl -n coachi get externalsecret                  # (after this PR merges) coachi-pg-app + cnpg-seaweedfs-s3 = SecretSynced
```

## 1. Freeze writes  ⚠️ DO THIS BEFORE MERGING THIS PR

The import is a point-in-time `pg_dump`; anything written after it starts is lost.
Scale the DB writers to 0 (leave the old `coachi-postgres` StatefulSet running — it's
the import source):

```sh
kubectl -n coachi scale deploy/coachi-api deploy/coachi-mcp --replicas=0
kubectl -n coachi scale statefulset/coachi-paseo --replicas=0
kubectl -n coachi get pods        # confirm api/mcp/paseo gone; coachi-postgres-0 still Running
```

## 2. Merge this PR → let the import run

ArgoCD creates the ESO secrets, ObjectStore, Cluster, ScheduledBackup. The cluster
bootstraps by importing from the now-quiet `coachi-postgres`.

```sh
kubectl -n coachi get cluster coachi-pg -w     # wait for: "Cluster in healthy state"
kubectl cnpg status coachi-pg                   # primary ready, import done
```

If the import container errors, check `kubectl -n coachi logs job/coachi-pg-1-initdb` (name may vary).

## 3. Validate backup + PITR  🔒 HARD GATE — do not proceed until this passes

```sh
# Take an on-demand base backup via the plugin
kubectl cnpg backup coachi-pg --method=plugin
kubectl -n coachi get backup                    # Completed
```

Confirm objects landed in SeaweedFS (this is where the SeaweedFS checksum fix is proven):

```sh
# from an mc-capable pod / the coachi-db-backup image
mc ls -r store/coachi-media/backups/cnpg/coachi/
```

Optional but recommended — prove a PITR restore into a **throwaway** cluster
(read-only w.r.t. source; never mutate the live DB):

```yaml
# coachi-pg-restore.yaml (apply manually, delete after)
spec:
  instances: 1
  storage: { storageClass: longhorn-cnpg, size: 8Gi }
  bootstrap:
    recovery:
      source: coachi-origin
      recoveryTarget: { targetTime: "<RFC3339 time WITH timezone>" }
  externalClusters:
    - name: coachi-origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: { barmanObjectName: coachi-backup-store, serverName: coachi-pg-v1 }
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters: { barmanObjectName: coachi-backup-store, serverName: coachi-pg-restore-v1 }
```

## 4. Cutover — merge the cutover PR

Merging it repoints coachi-api/mcp (and the interim pg_dump job) at `coachi-pg-rw`
and ArgoCD applies it. Then bring the app back up:

```sh
kubectl -n coachi scale deploy/coachi-api deploy/coachi-mcp --replicas=1
kubectl -n coachi scale statefulset/coachi-paseo --replicas=1
kubectl -n coachi logs deploy/coachi-api | tail     # connects to coachi-pg-rw, healthy
```

Smoke-test coachi.arsenikki.casa.

## 5. Rollback (if coachi misbehaves post-cutover)

The old `coachi-postgres` StatefulSet is untouched (import only read it). Revert the
cutover PR (host back to `coachi-postgres`), scale the app back up — you're on
known-good data in minutes. (Caveat: writes made to CNPG after cutover are not on the
old DB; for a pilot that window is tiny.)

## 6. Decommission (only after a clean 30-day retention cycle + a proven restore)

Keep the old StatefulSet **scaled to 0** and the pg_dump CronJob running for one full
retention cycle as belt-and-suspenders. Then, in a final PR, delete
`cluster/apps/coachi/postgres.yaml` + `backup.yaml` (ArgoCD prunes on merge — commit
the deletion, don't hand-delete). **Keep the rclone→Drive offsite job (#700) forever.**
Then repeat this whole runbook for untappi (Phase 3, PostGIS image + extension bootstrap).
