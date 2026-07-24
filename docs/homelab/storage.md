---
title: Storage
description: Persistent storage on kuberseni — Longhorn block storage, TrueNAS NFS for media, and the in-cluster SeaweedFS S3 object store.
---

Persistent storage on the [cluster](/cluster/) uses three backends:

| Backend | Type | StorageClass / access | Used for |
|---|---|---|---|
| **Longhorn** | Distributed block (CSI) | `longhorn` (RWO) | App config PVCs, observability PVCs, SeaweedFS backing volumes |
| **TrueNAS NFS** | Network file (RWX) | Static PV, `storageClassName: ""` | Bulk media library (shared by media apps) |
| **SeaweedFS** | In-cluster S3 object store | Service `seaweedfs-s3.monitoring:8333` | Mimir / Loki / Tempo blocks + chunks |

Both Longhorn and SeaweedFS are deployed by ArgoCD (sync-wave `2`, the storage wave). SeaweedFS is itself backed by Longhorn PVCs.

## Longhorn (default block storage)

Longhorn is the primary CSI provider — a Helm release managed by ArgoCD.

- **Chart / version:** `longhorn` `1.11.2` from `https://charts.longhorn.io` (`cluster/argocd/apps/longhorn.yaml`).
- **Namespace:** `longhorn-system` (Pod Security `enforce: privileged` — Longhorn needs hostPath + block-device access; `cluster/apps/longhorn/resources/namespace.yaml`).
- **StorageClass:** `longhorn` — the chart-provisioned default class (no explicit `StorageClass` manifest exists in the repo; PVCs simply reference `storageClassName: longhorn`).
- **UI:** `longhorn.arsenikki.casa` via Traefik, behind Authentik forward-auth.

### Replication & placement

From `cluster/apps/longhorn/values.yaml`:

- `defaultReplicaCount: 2` (and `defaultClassReplicaCount: 2`) — every volume keeps 2 replicas.
- `replicaSoftAntiAffinity: false` — **hard** anti-affinity: Longhorn refuses to co-locate both replicas of a volume on the same node. With only 2 storage nodes this means a node down/full leaves affected volumes **degraded** rather than silently collapsing redundancy. This was set false after the 2026-07-04 incident where worker-02 filled with orphaned replicas, became unschedulable, and all 32 volumes stacked both replicas on worker-01.
- `replicaAutoBalance: best-effort`.
- `orphanResourceAutoDeletion: "replica-data;instance"` — auto-deletes orphaned replica/instance resources so a storage node can't silently fill with stale replica directories (the root cause of the 2026-07-04 collapse).
- `taintToleration` + manager tolerations let the CSI plugin and manager run on control-plane nodes so pods scheduled there can still mount Longhorn volumes (data itself lives on the worker disks).

### Data disk (on-node)

Longhorn stores replica data at `defaultDataPath: /var/mnt/longhorn-data` — a **dedicated data disk**, not the Talos OS disk.

- **worker-02:** Talos patch `infra/talos/patches/worker-storage.yaml` mounts `/dev/sdb` at `/var/mnt/longhorn-data` and labels the node `node.kubernetes.io/storage-node=true`.
- **worker-01:** talconfig notes a 50GB OS disk + 500GB Longhorn data disk (`infra/talos/talconfig.yaml`).
- `createDefaultDiskLabeledNodes: true` — only nodes carrying the create-default-disk label become storage nodes; control-planes do not.

### fstrim reclaim (CronJob)

Talos mounts the data disk **without** `discard` and runs no fstrim, so blocks freed by Longhorn (deleted/rebuilt/orphaned replicas) never propagate back to the underlying Proxmox LVM-thin pool — which ratchets toward full (on 2026-07-04 it hit 100% on nas and froze the VMs).

`cluster/apps/longhorn/resources/fstrim-cronjob.yaml` runs a weekly privileged `fstrim -v /data`:

- Schedule `0 3 * * 0` (Sundays 03:00), `concurrencyPolicy: Forbid`.
- `completions: 2` / `parallelism: 2` with pod anti-affinity on `kubernetes.io/hostname` → exactly one fstrim per storage node.
- Targets `nodeSelector: node.longhorn.io/create-default-disk: "true"`, mounts hostPath `/var/mnt/longhorn-data`.

## Declaring a PVC

Apps request block storage with a plain PVC referencing the `longhorn` class. Canonical example (`cluster/apps/media/sonarr/pvc.yaml`):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sonarr-config
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: longhorn
```

Most app config PVCs follow this shape (e.g. `home-assistant-config` at 1Gi in `home-automation`). Longhorn is `ReadWriteOnce` — for shared read-write across pods, use the NFS PV below.

## TrueNAS NFS (bulk media, RWX)

The media library is too large for Longhorn replication, so it's served over NFS from TrueNAS and mounted `ReadWriteMany`. Declared as a **static** PV + PVC in `cluster/apps/media/plex/media-pvc.yaml`:

- **Server:** `192.168.1.2` (TrueNAS — `truenas.arsenikki.casa`, per `cluster/apps/external-dns/infra-hosts.yaml`), NFS v4.
- **Capacity:** `14000Gi`, `accessModes: ReadWriteMany`, `persistentVolumeReclaimPolicy: Retain`.
- The PVC binds by `volumeName: media-pv` with `storageClassName: ""` (no dynamic provisioning).

## SeaweedFS (in-cluster S3 object store)

SeaweedFS provides S3-compatible object storage for the observability stack — it is **not** a general-purpose bucket store for arbitrary apps.

- **Chart / version:** `seaweedfs` `4.34.0` from `https://seaweedfs.github.io/seaweedfs/helm` (`cluster/argocd/apps/seaweedfs.yaml`), sync-wave `2`.
- **Namespace:** `monitoring`.
- **S3 endpoint:** service `seaweedfs-s3.monitoring.svc:8333` (plain HTTP, in-cluster only), auth enabled.
- **Topology:** single-node — `master`, `volume`, `filer`, and `s3` each `replicas: 1`.
- **Persistence:** every component uses **Longhorn** PVCs (`storageClass: longhorn`), because the chart's default hostPath dirs (`/ssd`, `/storage`) don't exist on Talos' read-only rootfs. Sizes: master `2Gi`, volume data `50Gi`, volume idx `5Gi`, filer `5Gi`; logs are `emptyDir`.

### Buckets

Declaratively pre-created via `createBuckets` in `cluster/apps/monitoring/seaweedfs/values.yaml`:

| Bucket | Consumer |
|---|---|
| `mimir-blocks` | Mimir blocks |
| `mimir-ruler` | Mimir ruler |
| `mimir-alertmanager` | Mimir alertmanager |
| `loki-data` | Loki chunks + ruler (shared) |
| `tempo-data` | Tempo trace blocks |

Mimir requires **separate** buckets for blocks/ruler/alertmanager; Loki shares one.

### S3 credentials (ESO)

`cluster/apps/monitoring/seaweedfs/externalsecrets.yaml` templates two secrets from the 1Password item `seaweedfs-s3` (fields `access_key`, `secret_key`) via the `onepassword` ClusterSecretStore:

- `seaweedfs-s3-config` — SeaweedFS S3 identity JSON (single `monitoring` identity with `Admin,Read,Write,List,Tagging`), consumed by the S3 gateway (`existingConfigSecret`).
- `seaweedfs-s3` — raw keys as env vars: `S3_ACCESS_KEY` / `S3_SECRET_KEY` (Mimir, via `-config.expand-env`) and `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (Loki, via the AWS SDK env chain).

### Vacuum reclaim (CronJob)

SeaweedFS only auto-compacts a volume once 30% of its data is deleted, but Mimir compaction produces only 17–27% garbage — so it never triggers and the backing Longhorn PVC (and LVM-thin pool) fills. `cluster/apps/monitoring/seaweedfs/vacuum-cronjob.yaml` runs a daily `weed shell` vacuum at a lower threshold:

- Schedule `0 4 * * *` (daily 04:00), `concurrencyPolicy: Forbid`.
- Command: `volume.vacuum -garbageThreshold=0.1` against `seaweedfs-master:9333` / `seaweedfs-filer:8888`.

## Reclaim chain

Because Talos never trims and the pool is thin-provisioned, freed space has to be walked all the way back to Proxmox. Two CronJobs keep it from filling:

```mermaid
flowchart LR
  App[App / Mimir deletes data] --> SW[SeaweedFS volume]
  SW -->|"seaweedfs-vacuum (daily 04:00)"| LH[Longhorn PVC]
  App2[Deleted/rebuilt replicas] --> LH
  LH -->|"longhorn-fstrim (Sun 03:00)"| Disk[/var/mnt/longhorn-data]
  Disk -->|discard=on qemu disk| LVM[Proxmox LVM-thin pool]
```

