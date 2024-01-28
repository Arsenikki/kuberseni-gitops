<div align="center">
  <img width="500" height="250" src="https://github.com/Arsenikki/kuberseni-gitops/blob/main/docs/public/tech-stack.drawio.png?raw=true">

## :rocket: GitOps supercharged Kubernetes cluster :sailboat:
:computer: Virtualized infrastructure with [Proxmox](https://www.proxmox.com/en/)

:wrench: VM provisioning and cluster bootstrapping with [Ansible](https://www.ansible.com/)

:robot: Application workload management with [Flux](https://github.com/fluxcd/flux2)
</div>

---

## :gear:&nbsp; Hardware

| Node             | CPU       | RAM       | Storage                             | Function                                   | Operating System |
|------------------|-----------|-----------|-------------------------------------|--------------------------------------------|------------------|
| Minisforum NBP5  | i5 13500H | 32GB DDR5 | 1TB   m.2                           | 1x k3s Master<br>1x k3s Worker (with iGPU) | Proxmox 8.x      |
| Custom NAS build | N5105     | 32GB DDR4 | 256GB m.2<br>16TB  HDD<br>10TB  HDD | TrueNAS<br>1x k3s Master<br>1x k3s Worker  | Proxmox 8.x      |
| Topton router    | N5105     | 16GB DDR4 | 512GB m.2                           | OPNSense<br>1x k3s Master                  | Proxmox 8.x      |

---

## :open_file_folder:&nbsp; Repository structure

- **bootstrapping** directory contains Ansible playbooks and roles. It's used to spin up VMs inside proxmox, configure those VMs, and lastly bootstrap the k3s Kubernetes cluster.
- **cluster** directory contains Kubernetes application workloads with following sub-dirs:
  - **flux** directory is the entrypoint to Flux
  - **core** directory (depends on **flux**) are important infrastructure applications (grouped by namespace). Flux is configured to not prune these resources automatically.
  - **apps** directory (depends on **core**) is where common applications (grouped by namespace) are placed. Flux will prune resources here if they are not tracked by Git anymore

---

## :lock_with_ink_pen:&nbsp; Secret and configuration management

Secrets are encrypted with [sops](https://github.com/mozilla/sops) using [age](https://github.com/FiloSottile/age) before being pushed into this repository. Flux is configured to automatically decrypt these secrets inside the cluster. This allows secret values to be configured in [cluster-secrets.yaml](cluster/base/cluster-secrets.yaml) and in [cluster-settings.yaml](cluster/base/cluster-settings.yaml).

---

## :robot:&nbsp; Automation

* [Renovate](https://github.com/renovatebot/renovate) helps keep workloads up-to-date by scanning the repo and opening pull requests when it detects a new container image update or a new helm chart in the upstream repository
* [Container images](https://github.com/Arsenikki/container-images): Some self-managed container images are automatically built using Github Actions once a new version is detected in the upstream container image registry. Both AMD64 and ARM architectures supported and Trivy is used to scan and provide vulnerability reporting for the produced images. NOTE: This is no longer maintained.
