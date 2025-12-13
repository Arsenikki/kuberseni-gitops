import os
import subprocess
from typing import Dict

from temporalio import activity


def run(cmd, cwd=None):
    subprocess.run(cmd, cwd=cwd, check=True)


@activity.defn
async def bootstrap_talos(cfg: Dict):
    """Bootstrap Talos control plane using repo scripts/module.
    Read-only unless ALLOW_APPLY=true.
    """
    repo_root = os.getenv("REPO_ROOT", ".")
    modules_talos = os.path.join(repo_root, "modules", "talos")
    script = os.path.join(modules_talos, "setup-talos-cluster.sh")

    if os.getenv("ALLOW_APPLY", "false").lower() != "true":
        # Dry-run or read-only behavior: print intended actions
        print("[DRY-RUN] Would execute:", script)
        return

    run(["bash", script], cwd=modules_talos)


@activity.defn
async def join_nodes(cfg: Dict):
    """Join worker nodes via talosctl calls.
    Requires ALLOW_APPLY=true for state-modifying operations.
    """
    if os.getenv("ALLOW_APPLY", "false").lower() != "true":
        print("[DRY-RUN] Would join worker nodes with talosctl")
        return

    # Example (placeholder commands):
    # run(["talosctl", "apply-config", "--insecure", "--nodes", nodes_csv, "--file", "worker.yaml"]) 
    print("Joining nodes... (implement node list and configs as needed)")


@activity.defn
async def upgrade_node(payload: Dict):
    """Upgrade a single node to target Talos version via talosctl upgrade.
    Respect safety flags.
    """
    node = payload["node"]
    cfg = payload["cfg"]

    if os.getenv("ALLOW_APPLY", "false").lower() != "true":
        print(f"[DRY-RUN] Would upgrade {node['hostname']} to {cfg['target_talos_version']}")
        return

    # Example upgrade command
    # talosctl upgrade --nodes <ip> --image ghcr.io/siderolabs/talos:<version> --preserve
    run([
        "talosctl", "upgrade",
        "--nodes", node["ip"],
        "--image", f"ghcr.io/siderolabs/talos:{cfg['target_talos_version']}",
        "--preserve",
    ])
