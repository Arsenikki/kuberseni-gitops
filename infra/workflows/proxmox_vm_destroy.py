"""
Proxmox VM Destruction Workflow

This workflow handles the destruction of Proxmox VMs using OpenTofu.
"""

from datetime import timedelta
from temporalio import workflow

from activities.vm import destroy_proxmox_infrastructure


@workflow.defn
class ProxmoxVMDestroyWorkflow:
    """Workflow to destroy Proxmox VMs"""

    def __init__(self):
        self._destroy_approved = False

    @workflow.run
    async def run(self, config: dict) -> dict:
        """Execute the VM destruction workflow"""
        
        # Set up retry policy
        from temporalio.common import RetryPolicy
        retry_policy = RetryPolicy(
            maximum_interval=timedelta(minutes=2),
            maximum_attempts=3
        )

        workflow.logger.info(f"Starting Proxmox VM destruction for {config.get('cluster_name', 'unknown')}")
        
        # Step 1: Wait for approval (for safety)
        workflow.logger.info("Step 1: Waiting for destruction approval")
        await workflow.wait_condition(lambda: self._destroy_approved)
        
        # Step 2: Destroy infrastructure
        workflow.logger.info("Step 2: Destroying Proxmox infrastructure")
        await workflow.execute_activity(
            destroy_proxmox_infrastructure,
            {
                "infra_path": config.get("infra_path", "./terraform"),
                "auto_approve": True
            },
            start_to_close_timeout=timedelta(minutes=15),
            retry_policy=retry_policy
        )
        
        workflow.logger.info("🧹 Proxmox VMs destroyed successfully!")
        
        return {
            "status": "success",
            "message": "Proxmox VMs destroyed successfully",
            "cluster_name": config.get("cluster_name")
        }

    @workflow.signal
    async def approve_destroy(self):
        """Signal to approve VM destruction"""
        workflow.logger.info("🔥 VM destruction approved")
        self._destroy_approved = True
