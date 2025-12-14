from datetime import timedelta
from temporalio import workflow
from temporalio.common import RetryPolicy

from activities.vm import (
    plan_proxmox_infrastructure,
    apply_proxmox_infrastructure,
    get_terraform_outputs
)


@workflow.defn
class ProxmoxVMInstallWorkflow:
    def __init__(self):
        self._apply_approved = False

    @workflow.signal
    def approve_apply(self):
        """Signal to approve infrastructure apply"""
        self._apply_approved = True

    @workflow.run
    async def run(self, config: dict) -> dict:
        """
        Install Proxmox VMs using OpenTofu
        
        config should contain:
        {
            "infra_path": "./infra/proxmox",
            "cluster_name": "kuberseni-cluster"
        }
        """
        
        retry_policy = RetryPolicy(
            initial_interval=timedelta(seconds=5),
            maximum_interval=timedelta(seconds=30),
            maximum_attempts=3
        )

        workflow.logger.info(f"Starting Proxmox VM installation for {config.get('cluster_name', 'unnamed-cluster')}")
        
        # Step 1: Plan infrastructure
        workflow.logger.info("Step 1: Planning infrastructure changes")
        plan_result = await workflow.execute_activity(
            plan_proxmox_infrastructure,
            config,
            start_to_close_timeout=timedelta(minutes=5),
            retry_policy=retry_policy
        )
        
        # Step 2: Wait for approval
        workflow.logger.info("Step 2: Waiting for infrastructure apply approval...")
        await workflow.wait_condition(lambda: self._apply_approved)
        
        # Step 3: Apply infrastructure
        workflow.logger.info("Step 3: Applying infrastructure changes")
        apply_config = {**config, "auto_approve": True}
        await workflow.execute_activity(
            apply_proxmox_infrastructure,
            apply_config,
            start_to_close_timeout=timedelta(minutes=20),
            retry_policy=retry_policy
        )
        
        # Step 4: Extract outputs for next workflow
        workflow.logger.info("Step 4: Extracting Terraform outputs")
        outputs = await workflow.execute_activity(
            get_terraform_outputs,
            config,
            start_to_close_timeout=timedelta(minutes=2),
            retry_policy=retry_policy
        )
        
        workflow.logger.info(f"Proxmox VMs installed successfully. Found {len(outputs['control_plane_nodes'])} control plane nodes")
        
        return {
            "status": "completed",
            "cluster_config": {
                "cluster_name": config.get("cluster_name", "kuberseni-cluster"),
                "control_plane_nodes": outputs["control_plane_nodes"],
                "worker_nodes": [],  # Add worker support later if needed
                "vm_info": outputs["vm_info"]
            }
        }
