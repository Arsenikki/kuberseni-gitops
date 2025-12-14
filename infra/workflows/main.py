from temporalio import workflow
from datetime import timedelta

from workflows.proxmox_vm_install import ProxmoxVMInstallWorkflow
from workflows.proxmox_vm_destroy import ProxmoxVMDestroyWorkflow
from workflows.talos_cluster_install import TalosClusterBootstrapWorkflow
from workflows.talos_cluster_upgrade import TalosClusterUpgradeWorkflow


@workflow.defn
class MainWorkflow:
    def __init__(self):
        self.proxmox_child = None
        self.bootstrap_child = None
        self.upgrade_child = None
        self.destroy_child = None
        
        self._proxmox_approval_received = False
        self._bootstrap_approval_received = False
        self._upgrade_approval_received = False
        self._destroy_approval_received = False

    @workflow.signal
    async def approve_proxmox_apply(self):
        """Approve Proxmox infrastructure apply"""
        self._proxmox_approval_received = True
        if self.proxmox_child:
            await self.proxmox_child.signal("approve_apply")

    @workflow.signal
    async def approve_bootstrap(self):
        """Approve Talos cluster bootstrap"""
        self._bootstrap_approval_received = True
        if self.bootstrap_child:
            await self.bootstrap_child.signal("approve_bootstrap")

    @workflow.signal
    async def approve_upgrade(self):
        """Approve Talos cluster upgrade"""
        self._upgrade_approval_received = True
        if self.upgrade_child:
            await self.upgrade_child.signal("approve_upgrade")

    @workflow.signal
    async def approve_destroy(self):
        """Approve VM destruction"""
        self._destroy_approval_received = True
        if self.destroy_child:
            await self.destroy_child.signal("approve_destroy")

    @workflow.signal
    async def approve_current_node_upgrade(self):
        """Approve current node upgrade (for upgrade workflow)"""
        if self.upgrade_child:
            await self.upgrade_child.signal("approve_current_node")

    @workflow.run
    async def run(self, config: dict) -> dict:
        """
        Main workflow to orchestrate full cluster lifecycle
        
        config should contain:
        {
            "operation": "install" | "bootstrap" | "upgrade" | "full",
            "cluster_name": "kuberseni-cluster",
            "infra_path": "./infra/proxmox",
            "target_talos_version": "v1.11.5",  # for upgrades
            "skip_proxmox": false,  # for bootstrap-only
            "upgrade_strategy": "rolling"  # for upgrades
        }
        """
        
        operation = config.get("operation", "full")
        cluster_name = config.get("cluster_name", "kuberseni-cluster")
        task_queue = workflow.info().task_queue
        
        workflow.logger.info(f"Starting {operation} operation for cluster {cluster_name}")
        
        results = {}
        
        # Step 1: Proxmox VM Installation (if needed)
        if operation in ["install", "full"] and not config.get("skip_proxmox", False):
            workflow.logger.info("Step 1: Starting Proxmox VM installation")
            
            proxmox_config = {
                "cluster_name": cluster_name,
                "infra_path": config.get("infra_path", "./terraform")
            }
            
            self.proxmox_child = await workflow.start_child_workflow(
                ProxmoxVMInstallWorkflow.run,
                proxmox_config,
                id=f"{cluster_name}-proxmox",
                task_queue=task_queue
            )
            
            # Wait for proxmox approval
            workflow.logger.info("Waiting for Proxmox infrastructure apply approval...")
            await workflow.wait_condition(lambda: self._proxmox_approval_received)
            
            # Send approval to child workflow
            workflow.logger.info("Sending apply approval to Proxmox child workflow...")
            await self.proxmox_child.signal("approve_apply")
            
            # Wait for child workflow to complete and get result
            workflow.logger.info("Waiting for Proxmox child workflow to complete...")
            proxmox_result = await self.proxmox_child
            results["proxmox"] = proxmox_result
            
            # Extract cluster config for next step
            cluster_config = proxmox_result["cluster_config"]
        
        # Step 2: Talos Cluster Bootstrap (if needed)
        if operation in ["bootstrap", "install", "full"]:
            workflow.logger.info("Step 2: Starting Talos cluster bootstrap")
            
            # Use cluster config from proxmox or from input
            if "cluster_config" in locals():
                bootstrap_config = cluster_config
            else:
                # Bootstrap-only mode - config must be provided
                bootstrap_config = config.get("cluster_config")
                if not bootstrap_config:
                    raise ValueError("cluster_config required for bootstrap-only operation")
            
            # Add talos version if specified
            if config.get("target_talos_version"):
                bootstrap_config["talos_version"] = config["target_talos_version"]
            
            self.bootstrap_child = await workflow.start_child_workflow(
                TalosClusterBootstrapWorkflow.run,
                bootstrap_config,
                id=f"{cluster_name}-bootstrap",
                task_queue=task_queue
            )
            
            # Wait for bootstrap approval
            workflow.logger.info("Waiting for Talos cluster bootstrap approval...")
            await workflow.wait_condition(lambda: self._bootstrap_approval_received)
            await self.bootstrap_child.signal("approve_bootstrap")
            
            # Get result
            bootstrap_result = await self.bootstrap_child.result()
            results["bootstrap"] = bootstrap_result
        
        # Step 3: Talos Cluster Upgrade (if requested)
        if operation in ["upgrade"]:
            workflow.logger.info("Step 3: Starting Talos cluster upgrade")
            
            upgrade_config = {
                "cluster_name": cluster_name,
                "target_talos_version": config.get("target_talos_version"),
                "control_plane_nodes": config.get("control_plane_nodes", []),
                "worker_nodes": config.get("worker_nodes", []),
                "upgrade_strategy": config.get("upgrade_strategy", "rolling"),
                "wait_between_nodes": config.get("wait_between_nodes", 120)
            }
            
            if not upgrade_config["target_talos_version"]:
                raise ValueError("target_talos_version required for upgrade operation")
            
            self.upgrade_child = await workflow.start_child_workflow(
                TalosClusterUpgradeWorkflow.run,
                upgrade_config,
                id=f"{cluster_name}-upgrade",
                task_queue=task_queue
            )
            
            # Wait for upgrade approval
            workflow.logger.info("Waiting for Talos cluster upgrade approval...")
            await workflow.wait_condition(lambda: self._upgrade_approval_received)
            await self.upgrade_child.signal("approve_upgrade")
            
            # Get result
            upgrade_result = await self.upgrade_child.result()
            results["upgrade"] = upgrade_result
        
        # Step 4: Destroy Infrastructure (if requested)
        if operation in ["destroy"]:
            workflow.logger.info("Step 4: Starting Proxmox VM destruction")
            
            destroy_config = {
                "cluster_name": cluster_name,
                "infra_path": config.get("infra_path", "./terraform")
            }
            
            # Start destroy child workflow
            self.destroy_child = await workflow.start_child_workflow(
                ProxmoxVMDestroyWorkflow.run,
                destroy_config,
                id=f"{cluster_name}-destroy",
                task_queue=task_queue
            )
            
            # Wait for destroy approval
            workflow.logger.info("Waiting for VM destruction approval...")
            await workflow.wait_condition(lambda: self._destroy_approval_received)
            await self.destroy_child.signal("approve_destroy")
            
            # Get result
            destroy_result = await self.destroy_child.result()
            results["destroy"] = destroy_result
        
        workflow.logger.info(f"Main workflow completed successfully for {cluster_name}")
        
        return {
            "status": "completed",
            "operation": operation,
            "cluster_name": cluster_name,
            "results": results
        }
