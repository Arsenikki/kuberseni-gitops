import subprocess
from typing import Dict

from temporalio import activity


@activity.defn
async def cluster_health_check(cfg: Dict):
    # Read-only: kubectl get componentstatuses, nodes, pods in kube-system
    try:
        subprocess.run(["kubectl", "get", "nodes"], check=True)
        subprocess.run(["kubectl", "get", "pods", "-n", "kube-system"], check=True)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Cluster health check failed: {e}")


@activity.defn
async def node_health_check(payload: Dict):
    node = payload["node"]
    # Read-only: check node Ready status
    try:
        subprocess.run(["kubectl", "get", "node", node["hostname"], "-o", "wide"], check=True)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Node health check failed: {e}")
