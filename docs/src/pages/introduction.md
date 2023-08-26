---
title: Introduction
description: 🚀 GitOps supercharged Kubernetes cluster ⛵️
layout: /src/layouts/MainLayout.astro
---

<div align="center">
🚀 GitOps supercharged Kubernetes cluster ⛵️

..managed by Flux 🤖

..running on hyper-converged infrastructure 🙀

  <img width="100%" src="/tech-stack.drawio.png">


</div>

## 📚 Overview

This repository is my home Kubernetes cluster in a declarative state.
[Flux](https://github.com/fluxcd/flux2) watches my [cluster](./cluster/) directory and makes the changes to my cluster based on the YAML manifests.

---

## ⚙️ Hardware

| Node                      | RAM       | Storage                          | Function                           | Operating System | Quantity |
|---------------------------|-----------|----------------------------------|------------------------------------|------------------|----------|
| Dell Precision Tower 7810 | 64GB DDR4 | 2x 600GB SAS + 10TB IronWolf Pro | 3x Virtualized master/worker nodes | Harvester 1.0.3  | 1        |
| Custom PC build           | 32GB DDR4 | 256GB m.2 + 16TB Exos X16        | 1x Worker node with iGPU           | Proxmox 7.2      | 1        |

---

## 📂 Repository structure

The Git repository contains the following directories under `cluster` and are ordered below by how Flux will apply them.

- **base** directory is the entrypoint to Flux
- **crds** directory contains custom resource definitions (CRDs) that need to exist globally in your cluster before anything else exists
- **core** directory (depends on **crds**) are important infrastructure applications (grouped by namespace) that should never be automatically pruned by Flux. These are automatically protected by finalizers.
- **apps** directory (depends on **core**) is where your common applications (grouped by namespace) could be placed, Flux will prune resources here if they are not tracked by Git anymore

---

## 🤖 Automation

* [Renovate](https://github.com/renovatebot/renovate) keeps workloads up-to-date by scanning the repo and opening pull requests when it detects a new container image update or a new helm chart in the upstream repository
* [Container images](https://github.com/Arsenikki/container-images): Some self-managed container images are automatically built using Github Actions once a new version is detected in the upstream container image registry. Both AMD64 and ARM architectures supported and Trivy is used to scan and provide vulnerability reporting for the produced images.

---

## 🔐 Secret and config management

Secrets are encrypted using [sops](https://github.com/mozilla/sops) before being pushed into this repository.
The encrypted secrets are then decrypted by sops using the private key inside the cluster.
For encryption/decryption, I use [age](https://github.com/FiloSottile/age).
Secrets environment variables for the cluster are in [cluster-secrets.yaml](cluster/base/cluster-secrets.yaml).
The non-secret variables are in [cluster-settings.yaml](cluster/base/cluster-settings.yaml).

---

## 🤝 Community

There is an awesome community out there doing similar stuff at [awesome-home-kubernetes](https://github.com/k8s-at-home/awesome-home-kubernetes)!

There is also an active the [k8s@home Discord](https://discord.gg/7PbmHRK) for this community and great discussion.
