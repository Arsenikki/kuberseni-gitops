# GitOps supercharged k8s cluster running on hyper-converged infrastructure

![Kubernetes](docs/tech-stack.drawio.png)


## :book:&nbsp; Overview

Leverage [Flux2](https://github.com/fluxcd/flux2) to automate cluster state using code residing in this repo

## :computer:&nbsp; Infrastructure

See the [k3s setup](https://github.com/billimek/homelab-infrastructure/tree/master/k3s) in the [homelab-infrastructure repo](https://github.com/billimek/homelab-infrastructure) for more detail about hardware and infrastructure

## :gear:&nbsp; Setup

See [setup](setup/README.md) for more detail about setup & bootstrapping a new cluster

## :wrench:&nbsp; Workloads (by namespace)

* [cert-manager](cert-manager/)
* [default](default/)
* [flux-system-extra](flux-system-extra/)
* [kube-system](kube-system/)
* [logs](logs/)
* [monitoring](monitoring/)
* [rook-ceph](rook-ceph/)
* [system-upgrade](system-upgrade/)
* [velero](velero/)

## :robot:&nbsp; Automation

* [Renovate](https://github.com/renovatebot/renovate) keeps workloads up-to-date by scanning the repo and opening pull requests when it detects a new container image update or a new helm chart
- [Kured](https://github.com/weaveworks/kured) automatically drains & reboots nodes when OS patches are applied requiring a reboot
- [System Upgrade Controller](https://github.com/rancher/system-upgrade-controller) automatically upgrades k3s to new versions as they are released

## :handshake:&nbsp; Community

There is a really great community of like-minded folks doing similar efforts who have shared their clusters over at [awesome-home-kubernetes](https://github.com/k8s-at-home/awesome-home-kubernetes)

There is also an active the k8s@home [Discord](https://discord.gg/7PbmHRK) for this community and great discussion.

## :open_file_folder:&nbsp; Repository structure

The Git repository contains the following directories under `cluster` and are ordered below by how Flux will apply them.

- **base** directory is the entrypoint to Flux
- **crds** directory contains custom resource definitions (CRDs) that need to exist globally in your cluster before anything else exists
- **core** directory (depends on **crds**) are important infrastructure applications (grouped by namespace) that should never be pruned by Flux
- **apps** directory (depends on **core**) is where your common applications (grouped by namespace) could be placed, Flux will prune resources here if they are not tracked by Git anymore

```
cluster
├── apps
│   ├── default
│   ├── networking
│   └── system-upgrade
├── base
│   └── flux-system
├── core
│   ├── cert-manager
│   ├── metallb-system
│   ├── namespaces
│   └── system-upgrade
└── crds
    └── cert-manager
```