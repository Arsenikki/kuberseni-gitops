from datetime import timedelta
from temporalio import workflow
from temporalio.common import RetryPolicy

from activities.talos import (
    upgrade_node,
    wait_for_node_ready,
    verify_cluster_health
)


@workflow.defn
class TalosClusterUpgradeWorkflow:
    def __init__(self):
        self._upgrade_approved = False
        self._current_node_approved = False
        self._current_node_index = 0

    @workflow.signal
    def approve_upgrade(self):
        """Signal to approve the overall upgrade process"""
        self._upgrade_approved = True

    @workflow.signal
    def approve_current_node(self):
        """Signal to approve upgrading the current node"""
        self._current_node_approved = True

    @workflow.run
    async def run(self, upgrade_config: dict) -> dict:
        """
        Upgrade a Talos cluster to a new version
        
        upgrade_config should contain:
        {
            "cluster_name": "kuberseni-cluster",
            "target_talos_version": "v1.11.6",
            "control_plane_nodes": [
                {"name": "control-plane-1", "ip": "192.168.1.146"},
                {"name": "control-plane-2", "ip": "192.168.1.163"},
                {"name": "control-plane-3", "ip": "192.168.1.154"}
            ],
            "worker_nodes": [],
            "upgrade_strategy": "rolling",  # or "parallel" for workers
            "wait_between_nodes": 120  # seconds
        }
        """
        
        retry_policy = RetryPolicy(
            initial_interval=timedelta(seconds=30),
            maximum_interval=timedelta(minutes=5),
            maximum_attempts=3
        )

        cluster_name = upgrade_config["cluster_name"]
        target_version = upgrade_config["target_talos_version"]
        
        workflow.logger.info(f"Starting Talos cluster upgrade: {cluster_name} -> {target_version}")
        
        # Step 1: Request overall upgrade approval
        workflow.logger.info("Step 1: Requesting upgrade approval")
        workflow.logger.info(f"⚠️  This will upgrade all nodes to {target_version}")
        await workflow.wait_condition(lambda: self._upgrade_approved)
        
        # Step 2: Upgrade control plane nodes (one by one for safety)
        workflow.logger.info("Step 2: Upgrading control plane nodes")
        control_plane_nodes = upgrade_config["control_plane_nodes"]
        
        for idx, node in enumerate(control_plane_nodes):
            self._current_node_index = idx
            self._current_node_approved = False
            
            workflow.logger.info(f"Ready to upgrade control plane {idx + 1}/{len(control_plane_nodes)}: {node['name']}")
            workflow.logger.info("⚠️  Waiting for approval to upgrade this node...")
            await workflow.wait_condition(lambda: self._current_node_approved)
            
            # Upgrade the node
            workflow.logger.info(f"Upgrading {node['name']} ({node['ip']})")
            await workflow.execute_activity(
                upgrade_node,
                {
                    "node_ip": node["ip"],
                    "node_name": node["name"],
                    "talos_version": target_version
                },
                start_to_close_timeout=timedelta(minutes=20),
                retry_policy=retry_policy
            )
            
            # Wait for node to be ready after upgrade
            workflow.logger.info(f"Waiting for {node['name']} to be ready after upgrade")
            await workflow.execute_activity(
                wait_for_node_ready,
                {"node_ip": node["ip"], "node_name": node["name"]},
                start_to_close_timeout=timedelta(minutes=15),
                retry_policy=retry_policy
            )
            
            # Verify cluster health after each control plane upgrade
            workflow.logger.info("Verifying cluster health")
            await workflow.execute_activity(
                verify_cluster_health,
                {
                    "control_plane_ips": [n["ip"] for n in control_plane_nodes],
                    "cluster_endpoint": f"https://{control_plane_nodes[0]['ip']}:6443"
                },
                start_to_close_timeout=timedelta(minutes=10),
                retry_policy=retry_policy
            )
            
            # Wait between nodes if configured
            wait_time = upgrade_config.get("wait_between_nodes", 0)
            if wait_time > 0 and idx < len(control_plane_nodes) - 1:
                workflow.logger.info(f"Waiting {wait_time} seconds before next node")
                await workflow.sleep(wait_time)
        
        # Step 3: Upgrade worker nodes (if any)
        worker_nodes = upgrade_config.get("worker_nodes", [])
        if worker_nodes:
            workflow.logger.info("Step 3: Upgrading worker nodes")
            strategy = upgrade_config.get("upgrade_strategy", "rolling")
            
            if strategy == "parallel":
                # Upgrade all workers in parallel
                workflow.logger.info("Upgrading all worker nodes in parallel")
                
                # Start all upgrades
                upgrade_handles = []
                for node in worker_nodes:
                    handle = workflow.execute_activity(
                        upgrade_node,
                        {
                            "node_ip": node["ip"],
                            "node_name": node["name"],
                            "talos_version": target_version
                        },
                        start_to_close_timeout=timedelta(minutes=20),
                        retry_policy=retry_policy
                    )
                    upgrade_handles.append((node, handle))
                
                # Wait for all to complete
                for node, handle in upgrade_handles:
                    await handle
                    workflow.logger.info(f"Worker {node['name']} upgraded")
                
                # Wait for all workers to be ready
                for node in worker_nodes:
                    await workflow.execute_activity(
                        wait_for_node_ready,
                        {"node_ip": node["ip"], "node_name": node["name"]},
                        start_to_close_timeout=timedelta(minutes=15),
                        retry_policy=retry_policy
                    )
            
            else:  # rolling upgrade
                workflow.logger.info("Upgrading worker nodes one by one")
                for idx, node in enumerate(worker_nodes):
                    workflow.logger.info(f"Upgrading worker {idx + 1}/{len(worker_nodes)}: {node['name']}")
                    
                    await workflow.execute_activity(
                        upgrade_node,
                        {
                            "node_ip": node["ip"],
                            "node_name": node["name"],
                            "talos_version": target_version
                        },
                        start_to_close_timeout=timedelta(minutes=20),
                        retry_policy=retry_policy
                    )
                    
                    await workflow.execute_activity(
                        wait_for_node_ready,
                        {"node_ip": node["ip"], "node_name": node["name"]},
                        start_to_close_timeout=timedelta(minutes=15),
                        retry_policy=retry_policy
                    )
                    
                    # Wait between worker upgrades
                    wait_time = upgrade_config.get("wait_between_nodes", 0)
                    if wait_time > 0 and idx < len(worker_nodes) - 1:
                        await workflow.sleep(wait_time)
        
        # Step 4: Final cluster health verification
        workflow.logger.info("Step 4: Final cluster health verification")
        await workflow.execute_activity(
            verify_cluster_health,
            {
                "control_plane_ips": [node["ip"] for node in control_plane_nodes],
                "cluster_endpoint": f"https://{control_plane_nodes[0]['ip']}:6443"
            },
            start_to_close_timeout=timedelta(minutes=10),
            retry_policy=retry_policy
        )
        
        workflow.logger.info(f"🎉 Cluster {cluster_name} successfully upgraded to {target_version}!")
        
        return {
            "status": "completed",
            "cluster_name": cluster_name,
            "upgraded_to_version": target_version,
            "control_plane_nodes": len(control_plane_nodes),
            "worker_nodes": len(worker_nodes)
        }
