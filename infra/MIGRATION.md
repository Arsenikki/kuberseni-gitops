# Talos Migration Progress

Migration from k3s/Ansible to Talos Linux + Terraform infrastructure.

---

## Existing Infrastructure

### Current k3s Cluster (OLD - to be replaced)

**VMs currently running:**
- `cp-01` - 192.168.1.51 (router node)
- `cp-02` - 192.168.1.52 (minipc node)  
- `cp-03` - 192.168.1.53 (nas node)
- `worker-01` - 192.168.1.61 (minipc node)
- ~~`worker-02` - 192.168.1.62 (nas node)~~ - Removed due to disk space constraints

**VIP:** 192.168.1.99 (shared across control planes)

### New Talos Cluster Plan

**Decision:** Deploy new Talos VMs on **different IP range** (192.168.1.41-44) to allow side-by-side operation during migration.

**Network Analysis:**
- DHCP Range: 192.168.1.100-199
- Old k3s cluster: .51-.53 (control), .61-.62 (workers), .99 (VIP)
- New Talos range: .41-.44 (below DHCP range, clean separation)

**New IP Assignment:**
- `192.168.1.41` - control-plane-01 (router node)
- `192.168.1.42` - control-plane-02 (minipc node)
- `192.168.1.43` - control-plane-03 (nas node)
- `192.168.1.44` - worker-01 (minipc node with Intel Arc GPU)

**New VIP:** `192.168.1.40`

**Topology:** 3 control plane + 1 worker (worker-02 removed due to NAS disk constraints)

---

## Phase 1: Preparation

**Status:** Complete ✅  
**Owner:** Claude  
**Dependencies:** None

### Tasks

- [x] **Choose new IP range** for Talos VMs - **Decision: 192.168.1.41-44, VIP: .40**
- [x] **Update IP addresses** in configuration files:
  - Updated `infra/talos/talconfig.yaml` with new IPs and hostnames
  - Updated `infra/terraform/vms.tf` with new IPs and hostnames
  - Removed `worker-02` from both files
  - Updated `infra/Taskfile.yml` with new hostnames
- [x] **Set up tooling** - Created `.mise.toml` to manage project dependencies:
  - talhelper, talosctl, sops, age, yq, opentofu, task
  - Run `task install` (or `mise install --locked`) to install all tools
  - Generated `mise.lock` with SHA256 checksums for supply chain security
- [x] Generate Talos cluster secrets
  ```bash
  task talos:gensecret
  ```
- [x] Encrypt `talsecret.yaml` with SOPS/age
  ```bash
  sops -e -i infra/talos/talsecret.yaml
  ```
- [x] Create Proxmox API token for Terraform
  ```bash
  cd infra && task terraform:create-api-token
  ```
  - Created via script: `infra/scripts/create-proxmox-token.sh`
  - Token created on 192.168.1.10
- [x] Create `infra/terraform/encrypted-secrets.yaml` with Proxmox credentials
  - Encrypted with SOPS (keys visible, values encrypted)
  - Used automatically via `sops exec-file` in Taskfile
  - Decrypted temporarily during tofu commands
- [ ] Verify Talos ISO will download to correct datastore on each Proxmox node
  - Check `variables.tf` for `iso_datastore` (default: "local")
  - Check `vm_datastore` (default: "local-lvm")
  - Ensure these datastores exist on router, minipc, and nas nodes

### Validation

- `talsecret.yaml` exists and is SOPS-encrypted
- `encrypted-secrets.yaml` exists with valid Proxmox credentials
- Can connect to Proxmox API: `cd infra && task terraform:plan`

---

## Phase 2: Infrastructure Provisioning

**Status:** Not Started  
**Owner:** —  
**Dependencies:** Phase 1

### Tasks

- [ ] Run Terraform to provision VMs
  ```bash
  task terraform:apply
  ```
- [ ] Verify all 4 VMs created successfully
  - control-plane-01 (router/192.168.1.41)
  - control-plane-02 (minipc/192.168.1.42)
  - control-plane-03 (nas/192.168.1.43)
  - worker-01 (minipc/192.168.1.44)
- [ ] Verify VMs boot into Talos maintenance mode
- [ ] Check network connectivity (ping each VM from local machine)

### Validation

- All VMs running in Proxmox
- VMs accessible on expected IPs
- Talos maintenance console accessible: `talosctl --nodes <ip> --insecure health`

---

## Phase 3: Talos Bootstrap

**Status:** Not Started  
**Owner:** —  
**Dependencies:** Phase 2

### Tasks

- [ ] Generate Talos machine configurations
  ```bash
  task talos:generate
  ```
- [ ] Review generated configs in `infra/talos/_out/`
- [ ] Apply config to control plane nodes
  ```bash
  task talos:apply-controlplane
  ```
- [ ] Wait for control plane nodes to reboot and become ready
- [ ] Bootstrap etcd cluster on cp-01
  ```bash
  task talos:bootstrap
  ```
- [ ] Apply config to worker nodes
  ```bash
  task talos:apply-workers
  ```
- [ ] Retrieve kubeconfig
  ```bash
  task talos:kubeconfig
  ```
- [ ] Verify cluster health
  ```bash
  kubectl get nodes
  kubectl get pods -A
  ```

### Validation

- All 5 nodes show "Ready" status
- Control plane pods running (kube-apiserver, etcd, etc.)
- Can run kubectl commands against cluster
- VIP (192.168.1.99) is accessible

---

## Phase 4: Core Infrastructure

**Status:** Not Started  
**Owner:** —  
**Dependencies:** Phase 3

### Tasks

#### 4.1 Flux Installation

- [ ] Install Flux into cluster
  ```bash
  # Follow flux bootstrap process for OCI repository or Git
  # Ensure SOPS/age secret is created for decryption
  ```
- [ ] Verify Flux controllers are running
  ```bash
  flux check
  kubectl -n flux-system get pods
  ```
- [ ] Apply cluster secrets and settings
  - Verify `cluster-secrets.yaml` decrypts correctly
  - Verify `cluster-settings.yaml` ConfigMap is created

#### 4.2 Cilium (CNI)

- [ ] Verify Cilium Kustomization syncs
- [ ] Check Cilium pods are running
  ```bash
  kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium
  ```
- [ ] Test pod-to-pod networking
- [ ] Verify L2 announcements for LoadBalancer IPs (192.168.1.70-89 range)
- [ ] Test LoadBalancer service creation

#### 4.3 cert-manager

- [ ] Verify cert-manager Kustomization syncs
- [ ] Check cert-manager pods running
- [ ] Verify ClusterIssuers are ready
- [ ] Test certificate issuance

#### 4.4 Storage (democratic-csi / Longhorn)

- [ ] Review storage provider configuration (TrueNAS CSI?)
- [ ] Verify storage Kustomization syncs
- [ ] Check CSI driver pods running
- [ ] Create test PVC and verify it binds
- [ ] Test pod can mount and write to volume

#### 4.5 Traefik (Ingress)

- [ ] Verify Traefik Kustomization syncs
- [ ] Check Traefik pods running
- [ ] Verify LoadBalancer IP assigned (from cluster-settings)
- [ ] Test basic HTTP ingress

#### 4.6 Authentik (SSO)

- [ ] Verify Authentik Kustomization syncs
- [ ] Check Authentik database and application pods
- [ ] Verify ingress accessible
- [ ] Test authentication flow

#### 4.7 Reloader

- [ ] Verify Reloader Kustomization syncs
- [ ] Test auto-reload on ConfigMap/Secret change

### Validation

- All Flux Kustomizations in `cluster/core/` show "Ready"
- Core infrastructure pods healthy
- Storage provisioning works
- Ingress routing works
- Certificates being issued

---

## Phase 5: Application Workloads

**Status:** Not Started  
**Owner:** —  
**Dependencies:** Phase 4

### Strategy

Migrate applications one namespace at a time. Test each before proceeding.

### Tasks

#### 5.1 default namespace

- [ ] Sync `cluster/apps/default/` Kustomization
- [ ] Verify homepage deployment
- [ ] Test homepage accessibility

#### 5.2 external-dns

- [ ] Sync external-dns Kustomization
- [ ] Verify DNS records being created/updated
- [ ] Test DNS resolution

#### 5.3 home-automation

- [ ] Sync home-automation namespace Kustomization
- [ ] Verify persistent volumes created
- [ ] Test each application:
  - [ ] Home Assistant
  - [ ] Mosquitto (MQTT broker)
  - [ ] Node-RED
  - [ ] ser2net
  - [ ] Zigbee2MQTT
- [ ] Verify device connectivity and automation flows

#### 5.4 media

- [ ] Sync media namespace Kustomization
- [ ] Verify large persistent volumes provisioned correctly
- [ ] Test each application:
  - [ ] Plex (verify transcoding, hardware acceleration if applicable)
  - [ ] Overseerr
  - [ ] Radarr
  - [ ] Sonarr
  - [ ] Lidarr
  - [ ] Readarr
  - [ ] Prowlarr
  - [ ] qBittorrent
  - [ ] Bazarr
  - [ ] Deemix
  - [ ] Immich
  - [ ] ytdl-sub
  - [ ] cast-sponsor-skip
- [ ] Verify media library access and playback

#### 5.5 monitoring

- [ ] Sync monitoring namespace Kustomization
- [ ] Test each component:
  - [ ] Prometheus
  - [ ] Grafana
  - [ ] Loki
  - [ ] kube-prometheus-stack
  - [ ] node-exporter
  - [ ] pve-exporter
- [ ] Verify metrics collection
- [ ] Import/verify Grafana dashboards
- [ ] Test alerting

#### 5.6 Other Applications

- [ ] n8n
- [ ] oauth2-proxy
- [ ] paperless-ngx
- [ ] meshcentral
- [ ] intel-gpu-plugin (if needed on worker-01)

### Validation

- All application Kustomizations showing "Ready"
- All pods running and healthy
- Persistent data accessible (no data loss)
- External access working (ingresses, LoadBalancers)
- Hardware acceleration working where needed (GPU on worker-01)

---

## Phase 6: Validation & Cleanup

**Status:** Not Started  
**Owner:** —  
**Dependencies:** Phase 5

### Tasks

- [ ] Full end-to-end testing of critical workflows
  - [ ] Media streaming (Plex)
  - [ ] Home automation triggers
  - [ ] Monitoring and alerting
  - [ ] Authentication via Authentik
- [ ] Performance testing
  - [ ] Check CPU/memory usage is reasonable
  - [ ] Verify storage I/O performance
  - [ ] Test GPU workloads on worker-01
- [ ] Documentation updates
  - [ ] Update README with Talos-specific instructions
  - [ ] Document Taskfile commands
  - [ ] Create troubleshooting guide
- [ ] Backup verification
  - [ ] Verify backup solutions work (Velero?)
  - [ ] Test restore procedure
- [ ] Cleanup old artifacts (if not already done)
  - [x] Remove old Ansible playbooks
  - [x] Remove k3s upgrade plans
  - [x] Remove old documentation site
- [ ] Create upgrade runbook (Talos, Kubernetes versions)
- [ ] Tag migration completion in Git

### Validation

- All workloads running stably for 48+ hours
- No unexpected errors in logs
- Monitoring shows healthy metrics
- Backups successful
- Team comfortable with new tooling

---

## Rollback Plan

If critical issues arise during migration:

1. **Before Phase 3:** Destroy VMs (`task terraform:destroy`) and revert
2. **During Phase 3-4:** Rebuild cluster from scratch (Talos configs are declarative)
3. **During Phase 5:** Pause Flux sync, restore from backup to old cluster if needed
4. **After Phase 6:** Maintain old cluster in standby for 1-2 weeks before decommissioning

---

## Notes & Learnings

### Blockers / Issues

_Track blockers here as they arise_

### Key Decisions

- Using talhelper for Talos config generation
- VIP (192.168.1.99) managed by Talos built-in functionality
- Cilium for CNI with L2 announcement for LoadBalancer services
- Keeping existing Flux OCI-based setup

### Useful Commands

```bash
# Full bootstrap from scratch
task up

# Check cluster health
kubectl get nodes
kubectl get kustomizations -A
flux get all -A

# Talos CLI examples
talosctl --talosconfig infra/talos/_out/talosconfig health
talosctl --talosconfig infra/talos/_out/talosconfig dashboard
talosctl --talosconfig infra/talos/_out/talosconfig logs kubelet

# Upgrade Talos version (update talconfig.yaml first)
task talos:upgrade
```

---

## Future Projects

### OPNSense Kubernetes Operator

**Goal:** Build a Kubernetes operator to manage OPNSense network configuration declaratively via CRDs.

**Motivation:**
- Centralize network infrastructure management in Kubernetes
- GitOps workflow for DHCP reservations, firewall rules, DNS records
- Automatic DHCP reservation when new VMs/Services are created
- Integration with LoadBalancer services (auto-create firewall rules)

**Architecture:**
```
┌─────────────────────────────────────────┐
│ Kubernetes Cluster                      │
│                                         │
│  ┌───────────────────────────────────┐ │
│  │ OPNSense Operator (Go/Kubebuilder)│ │
│  └──────────┬────────────────────────┘ │
│             │                           │
│  ┌──────────▼───────────────────┐      │
│  │ CRDs:                        │      │
│  │ - DHCPReservation            │      │
│  │ - FirewallRule               │      │
│  │ - DNSOverride                │      │
│  └──────────────────────────────┘      │
└──────────────┬──────────────────────────┘
               │ OPNSense REST API
               ▼
      ┌────────────────┐
      │ OPNSense Router│
      │ 192.168.1.1    │
      └────────────────┘
```

**Example CRD Usage:**
```yaml
apiVersion: network.kuberseni.io/v1alpha1
kind: DHCPReservation
metadata:
  name: talos-cp-01
  namespace: infrastructure
spec:
  mac: "BC:24:11:AA:00:01"
  ip: "192.168.1.41"
  hostname: "cp-01"
  description: "Talos control plane 01"
```

**Implementation Plan:**
1. **Phase 1: Setup**
   - [ ] Create new repo: `opnsense-operator`
   - [ ] Initialize with Kubebuilder
   - [ ] Set up OPNSense API client library
   - [ ] Add API credentials management (Secret)

2. **Phase 2: Core Functionality**
   - [ ] Implement `DHCPReservation` CRD
   - [ ] Controller logic for CRUD operations
   - [ ] Status reporting and conditions
   - [ ] Reconciliation loop

3. **Phase 3: Advanced Features**
   - [ ] `FirewallRule` CRD for auto-generated rules
   - [ ] `DNSOverride` CRD for Unbound DNS overrides
   - [ ] `TrafficShaper` CRD for QoS rules
   - [ ] Webhook for validation

4. **Phase 4: Integration**
   - [ ] Deploy to cluster via Flux
   - [ ] Migrate existing DHCP reservations to CRDs
   - [ ] Documentation and examples

**Tech Stack:**
- **Language:** Go
- **Framework:** Kubebuilder / Operator SDK
- **API Client:** Custom Go client for OPNSense REST API
- **Testing:** envtest, integration tests with test OPNSense instance

**Benefits:**
- ✅ Declarative network configuration
- ✅ Git-tracked network state
- ✅ Automatic remediation if manual changes occur
- ✅ Integration with existing GitOps workflow
- ✅ Audit trail via Kubernetes events

**Reference Projects:**
- External-DNS (similar pattern for DNS)
- cert-manager (certificate lifecycle management)
- Cloudflare Operator (external API integration)

**Status:** Not Started (tracked separately from migration)

---

## Timeline

- **Started:** _Not yet started_
- **Phase 1 Complete:** —
- **Phase 2 Complete:** —
- **Phase 3 Complete:** —
- **Phase 4 Complete:** —
- **Phase 5 Complete:** —
- **Phase 6 Complete:** —
- **Migration Complete:** —
