from temporalio import activity
import asyncio
import os


@activity.defn
async def terragrunt_plan() -> str:
    print("[fake] terragrunt plan: evaluating changes...")
    for i in range(1, 4):
        activity.heartbeat({"op": "terragrunt_plan", "progress": i * 25})
        await asyncio.sleep(1)
    print("[fake] terragrunt plan: no changes detected")
    return "terragrunt-plan-ok"


@activity.defn
async def terragrunt_apply() -> str:
    allow_apply = os.getenv("ALLOW_APPLY", "false").lower() == "true"
    print(f"[fake] terragrunt apply (ALLOW_APPLY={allow_apply})")
    for i in range(1, 5):
        activity.heartbeat({"op": "terragrunt_apply", "progress": i * 20, "allow_apply": allow_apply})
        await asyncio.sleep(1)
    print("[fake] terragrunt apply: completed")
    return "terragrunt-apply-ok"


@activity.defn
async def kubectl_get_nodes() -> str:
    print("[fake] kubectl get nodes: listing cluster nodes...")
    for i in range(1, 3):
        activity.heartbeat({"op": "kubectl_get_nodes", "progress": i * 50})
        await asyncio.sleep(1)
    print("[fake] kubectl get nodes: node/core-1 Ready, node/core-2 Ready")
    return "kubectl-get-nodes-ok"


@activity.defn
async def talosctl_read_config() -> str:
    print("[fake] talosctl read /machine/config: fetching config...")
    for i in range(1, 4):
        activity.heartbeat({"op": "talosctl_read_config", "progress": i * 25})
        await asyncio.sleep(1)
    print("[fake] talosctl read /machine/config: 18KB YAML")
    return "talosctl-read-config-ok"


@activity.defn
async def cluster_health_probe() -> str:
    print("[fake] cluster health: checking API, DNS, CNI...")
    for i in range(1, 4):
        activity.heartbeat({"op": "cluster_health_probe", "progress": i * 25})
        await asyncio.sleep(1)
    print("[fake] cluster health: all critical components healthy")
    return "cluster-health-ok"
