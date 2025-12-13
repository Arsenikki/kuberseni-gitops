import os
import subprocess
from typing import Dict

from temporalio import activity


@activity.defn
async def provision_vms(cfg: Dict):
    """
    Read-only by default. Runs `terragrunt plan` for the Proxmox module.
    If env ALLOW_APPLY=true is set, will run `terragrunt apply`.
    Respect repo safety rules.
    """
    repo_root = os.getenv("REPO_ROOT", ".")
    module_path = os.path.join(repo_root, "proxmox")

    # Terragrunt plan
    subprocess.run(["terragrunt", "plan"], cwd=module_path, check=True)

    if os.getenv("ALLOW_APPLY", "false").lower() == "true":
        subprocess.run(["terragrunt", "apply", "-auto-approve"], cwd=module_path, check=True)
