<div align="center">
  <img width="500" height="250" src="https://github.com/Arsenikki/kuberseni-gitops/blob/main/docs/public/tech-stack.drawio.png?raw=true">

## :rocket: GitOps supercharged Kubernetes cluster :sailboat:
:computer: Virtualized infrastructure with [Proxmox](https://www.proxmox.com/en/)

:wrench: Talos OS based VMs provisioned with [OpenTofu](https://opentofu.org/) for immutable infrastructure

:robot: Application workload management with [Argo CD](https://argo-cd.readthedocs.io/)
</div>

---

## :gear:&nbsp; Hardware

| Node             | CPU       | RAM       | Storage                             | Function                                   | Operating System |
|------------------|-----------|-----------|-------------------------------------|--------------------------------------------|------------------|
| Minisforum NBP5  | i5 13500H | 32GB DDR5 | 1TB   m.2                           | 1x Talos Master<br>1x Talos Worker (with iGPU) | Proxmox 8.x  |
| Custom NAS build | N5105     | 32GB DDR4 | 256GB m.2<br>16TB  HDD<br>10TB  HDD | TrueNAS<br>1x Talos Master<br>1x Talos Worker  | Proxmox 8.x  |
| Topton router    | N5105     | 16GB DDR4 | 512GB m.2                           | OPNSense<br>1x Talos Master                    | Proxmox 8.x  |

---

## :open_file_folder:&nbsp; Repository structure

- **infra** directory contains the infrastructure layer:
  - **terraform** provisions the Talos VMs on Proxmox (plus OPNSense and TrueNAS Scale config) with [OpenTofu](https://opentofu.org/); the encrypted Terraform state is committed to this repo.
  - **talos** holds the [Talhelper](https://github.com/budimanjojo/talhelper)-managed Talos machine configuration (`talconfig.yaml`, patches and secrets).
  - **scripts** / **Taskfile.yml** wrap the bootstrap workflow (`infra/scripts/bootstrap-cluster.sh` installs Cilium, Argo CD, External Secrets Operator and 1Password Connect onto a fresh cluster).
- **cluster** directory contains the Kubernetes GitOps tree with following sub-dirs:
  - **bootstrap** holds the Helm values for the components installed once during cluster bootstrap (Argo CD and External Secrets Operator), before GitOps takes over.
  - **argocd** is the entrypoint to GitOps: `root-app.yaml` is an app-of-apps that recurses this directory to discover the Argo CD `Application` objects under **apps/** and the `kuberseni` `AppProject` under **projects/**.
  - **apps** is where the actual workload manifests live (grouped by namespace) — both infrastructure components (cilium, cert-manager, longhorn, traefik, …) and end-user applications (media, home-automation, …). Each is synced by a matching Argo CD Application; pruning and self-heal are managed per-Application.

---

## :lock_with_ink_pen:&nbsp; Secret and configuration management

Secret management is split between two layers:

- **In-cluster application secrets** are delivered by the [External Secrets Operator](https://external-secrets.io/), which pulls values from a [1Password](https://1password.com/) `homelab` vault via a self-hosted 1Password Connect server (`ClusterSecretStore` named `onepassword`). Nothing sensitive for the running workloads is committed to Git.
- **Infrastructure secrets at rest** (Talos machine secrets in `infra/talos/talsecret.yaml`, the Terraform state and `secrets.tfvars`) are encrypted with [sops](https://github.com/getsops/sops) using [age](https://github.com/FiloSottile/age) before being committed, per the rules in [.sops.yaml](.sops.yaml).

---

## :robot:&nbsp; Automation

* [Renovate](https://github.com/renovatebot/renovate) helps keep workloads up-to-date by scanning the repo and opening pull requests when it detects a new container image update or a new helm chart in the upstream repository
* [Container images](https://github.com/Arsenikki/container-images): Some self-managed container images are automatically built using Github Actions once a new version is detected in the upstream container image registry. Both AMD64 and ARM architectures supported and Trivy is used to scan and provide vulnerability reporting for the produced images. NOTE: This is no longer maintained.
