# Temporal Workflows (Python) for Talos Management

This folder contains a Python Temporal worker and workflows to manage Talos cluster installation and upgrades at scale.

## Components
- `workflows/talos_installation.py`: Provisions VMs, bootstraps Talos, joins nodes, runs health checks.
- `workflows/talos_upgrade.py`: Performs rolling node upgrades with post-step health checks.
- `activities/`: Implements Terragrunt/Talos/Kubectl steps. State-modifying operations are gated by `ALLOW_APPLY` env var.
- `worker.py`: Registers workflows and activities and runs the Temporal worker.
- `requirements.txt`: Dependencies.

## Safety & Repo Rules
- Read-only operations (plans, `kubectl get`, `talosctl read`) are allowed.
- State-modifying ops (`terragrunt apply`, `talosctl apply-config`, `kubectl apply`) require `ALLOW_APPLY=true`.
- Destructive ops (`destroy`, `delete`) are not implemented and must never be run without explicit confirmation.
- Prefer `kubectl rollout restart` instead of deleting pods.

## Quick Start

### Local with uv

1. Install dependencies with uv:
```sh
uv pip install -e temporal-python
```

2. Run the worker:
```sh
export TEMPORAL_TARGET=localhost:7233
export TEMPORAL_TASK_QUEUE=talos-management
export REPO_ROOT="$PWD"
export ALLOW_APPLY=false
python temporal-python/worker.py
```

### Docker Compose (Temporal Server + Worker)

1. Start stack:
```sh
docker compose up --build -d
```

2. Open Temporal UI: http://localhost:8080

3. Worker logs:
```sh
docker compose logs -f worker
```

### Launch Workflows
- Talos Installation: schedule `TalosInstallationWorkflow` with a `ClusterConfig` payload.
- Talos Upgrade: schedule `TalosUpgradeWorkflow` with `UpgradeConfig` payload.

## Notes
- Activities currently shell out to `terragrunt`, `talosctl`, and `kubectl`. Ensure these CLIs are installed and configured on the worker host.
- Integrate with your existing `modules/talos` scripts for concrete commands and inputs.
