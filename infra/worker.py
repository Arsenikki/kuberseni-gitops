import os
import asyncio
from temporalio.worker import Worker
from temporalio.client import Client

# Workflows
from workflows.main import MainWorkflow
from workflows.proxmox_vm_install import ProxmoxVMInstallWorkflow
from workflows.proxmox_vm_destroy import ProxmoxVMDestroyWorkflow
from workflows.talos_cluster_install import TalosClusterBootstrapWorkflow
from workflows.talos_cluster_upgrade import TalosClusterUpgradeWorkflow

# Activities
from activities.vm import (
    plan_proxmox_infrastructure,
    apply_proxmox_infrastructure,
    get_terraform_outputs,
    destroy_proxmox_infrastructure
)
from activities.talos import (
    generate_machine_configs,
    apply_machine_config,
    bootstrap_cluster,
    wait_for_node_ready,
    get_kubeconfig,
    verify_cluster_health,
    upgrade_node
)


async def main():
    target = os.getenv("TEMPORAL_TARGET", "localhost:7233")
    task_queue = os.getenv("TEMPORAL_TASK_QUEUE", "talos-management")

    client = await Client.connect(target)

    workflows = [
        MainWorkflow,
        ProxmoxVMInstallWorkflow,
        ProxmoxVMDestroyWorkflow,
        TalosClusterBootstrapWorkflow,
        TalosClusterUpgradeWorkflow
    ]
    
    activities = [
        # Provisioning activities
        plan_proxmox_infrastructure,
        apply_proxmox_infrastructure,
        get_terraform_outputs,
        destroy_proxmox_infrastructure,
        # Talos activities
        generate_machine_configs,
        apply_machine_config,
        bootstrap_cluster,
        wait_for_node_ready,
        get_kubeconfig,
        verify_cluster_health,
        upgrade_node
    ]

    worker = Worker(
        client, 
        task_queue=task_queue, 
        workflows=workflows,
        activities=activities
    )
    await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
