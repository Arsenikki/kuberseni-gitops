from datetime import timedelta
from temporalio import workflow
from temporalio.common import RetryPolicy

from activities.talos import (
    generate_machine_configs,
    apply_machine_config,
    wait_for_node_ready,
    bootstrap_cluster,
    verify_cluster_health,
    get_kubeconfig
)

@workflow.defn
class TalosClusterBootstrapWorkflow:
    def __init__(self):
        self._bootstrap_approved = False

    @workflow.signal
    def approve_bootstrap(self):
        """Signal to approve the destructive bootstrap operation"""
        self._bootstrap_approved = True

    @workflow.run
    async def run(self, cluster_config: dict) -> dict:
        """
        Bootstrap a Talos cluster from existing VMs
        
        cluster_config should contain:
        {
            "cluster_name": "kuberseni-cluster",
            "cluster_endpoint": "https://192.168.1.146:6443",
            "control_plane_nodes": [
                {"name": "control-plane-1", "ip": "192.168.1.146"},
                {"name": "control-plane-2", "ip": "192.168.1.163"},
                {"name": "control-plane-3", "ip": "192.168.1.154"}
            ],
            "worker_nodes": [],
            "talos_version": "v1.11.5"
        }
        """
        
        retry_policy = RetryPolicy(
            initial_interval=timedelta(seconds=10),
            maximum_interval=timedelta(minutes=2),
            maximum_attempts=5
        )

        workflow.logger.info(f"Starting Talos cluster bootstrap for {cluster_config['cluster_name']}")
        
        # Derive cluster endpoint from first control plane node if not provided
        if not cluster_config.get("cluster_endpoint"):
            first_cp = cluster_config["control_plane_nodes"][0]
            # Handle both string IPs and dict format
            if isinstance(first_cp, dict):
                cluster_config["cluster_endpoint"] = f"https://{first_cp['ip']}:6443"
            else:
                cluster_config["cluster_endpoint"] = f"https://{first_cp}:6443"
        
        # Step 1: Generate machine configurations
        workflow.logger.info("Step 1: Generating Talos machine configurations")
        machine_configs = await workflow.execute_activity(
            generate_machine_configs,
            cluster_config,
            start_to_close_timeout=timedelta(minutes=5),
            retry_policy=retry_policy
        )
        
        # Step 2: Apply configurations to control plane nodes
        workflow.logger.info("Step 2: Applying configurations to control plane nodes")
        for i, node in enumerate(cluster_config["control_plane_nodes"]):
            # Handle both string IPs and dict format
            if isinstance(node, dict):
                node_ip = node["ip"]
                node_name = node["name"]
            else:
                node_ip = node
                node_name = f"control-plane-{i+1}"
            
            workflow.logger.info(f"Configuring {node_name} ({node_ip})")
            await workflow.execute_activity(
                apply_machine_config,
                {
                    "node_ip": node_ip,
                    "node_name": node_name,
                    "config_type": "controlplane",
                    "machine_config": machine_configs["controlplane"]
                },
                start_to_close_timeout=timedelta(minutes=10),
                retry_policy=retry_policy
            )
        
        # Step 3: Wait for all nodes to be ready
        workflow.logger.info("Step 3: Waiting for nodes to be ready")
        for i, node in enumerate(cluster_config["control_plane_nodes"]):
            # Handle both string IPs and dict format
            if isinstance(node, dict):
                node_ip = node["ip"]
                node_name = node["name"]
            else:
                node_ip = node
                node_name = f"control-plane-{i+1}"
            
            workflow.logger.info(f"Waiting for {node_name} to be ready")
            await workflow.execute_activity(
                wait_for_node_ready,
                {"node_ip": node_ip, "node_name": node_name},
                start_to_close_timeout=timedelta(minutes=15),
                retry_policy=retry_policy
            )
        
        # Step 4: Request bootstrap approval (destructive operation)
        workflow.logger.info("Step 4: Requesting bootstrap approval...")
        workflow.logger.info("⚠️  Bootstrap will initialize the cluster - this is destructive!")
        await workflow.wait_condition(lambda: self._bootstrap_approved)
        
        # Step 5: Bootstrap the cluster
        workflow.logger.info("Step 5: Bootstrapping cluster")
        bootstrap_node = cluster_config["control_plane_nodes"][0]
        if isinstance(bootstrap_node, dict):
            bootstrap_ip = bootstrap_node["ip"]
        else:
            bootstrap_ip = bootstrap_node
        
        await workflow.execute_activity(
            bootstrap_cluster,
            {
                "bootstrap_node_ip": bootstrap_ip,
                "cluster_name": cluster_config["cluster_name"]
            },
            start_to_close_timeout=timedelta(minutes=10),
            retry_policy=retry_policy
        )
        
        # Step 6: Verify cluster health
        workflow.logger.info("Step 6: Verifying cluster health")
        # Extract IPs handling both string and dict formats
        control_plane_ips = []
        for node in cluster_config["control_plane_nodes"]:
            if isinstance(node, dict):
                control_plane_ips.append(node["ip"])
            else:
                control_plane_ips.append(node)
        
        await workflow.execute_activity(
            verify_cluster_health,
            {
                "control_plane_ips": control_plane_ips,
                "cluster_endpoint": cluster_config["cluster_endpoint"]
            },
            start_to_close_timeout=timedelta(minutes=20),
            retry_policy=retry_policy
        )
        
        # Step 7: Configure worker nodes (if any)
        if cluster_config.get("worker_nodes"):
            workflow.logger.info("Step 7: Configuring worker nodes")
            for i, node in enumerate(cluster_config["worker_nodes"]):
                # Handle both string IPs and dict format
                if isinstance(node, dict):
                    node_ip = node["ip"]
                    node_name = node["name"]
                else:
                    node_ip = node
                    node_name = f"worker-{i+1}"
                
                workflow.logger.info(f"Configuring worker {node_name} ({node_ip})")
                await workflow.execute_activity(
                    apply_machine_config,
                    {
                        "node_ip": node_ip,
                        "node_name": node_name,
                        "config_type": "worker",
                        "machine_config": machine_configs["worker"]
                    },
                    start_to_close_timeout=timedelta(minutes=10),
                    retry_policy=retry_policy
                )
                
                await workflow.execute_activity(
                    wait_for_node_ready,
                    {"node_ip": node_ip, "node_name": node_name},
                    start_to_close_timeout=timedelta(minutes=15),
                    retry_policy=retry_policy
                )
        
        # Step 8: Extract kubeconfig
        workflow.logger.info("Step 8: Extracting kubeconfig")
        first_cp = cluster_config["control_plane_nodes"][0]
        if isinstance(first_cp, dict):
            control_plane_ip = first_cp["ip"]
        else:
            control_plane_ip = first_cp
        
        kubeconfig_result = await workflow.execute_activity(
            get_kubeconfig,
            {
                "control_plane_ip": control_plane_ip,
                "cluster_name": cluster_config["cluster_name"]
            },
            start_to_close_timeout=timedelta(minutes=5),
            retry_policy=retry_policy
        )
        
        workflow.logger.info(f"🎉 Talos cluster {cluster_config['cluster_name']} bootstrapped successfully!")
        
        return {
            "status": "completed",
            "cluster_name": cluster_config["cluster_name"],
            "cluster_endpoint": cluster_config["cluster_endpoint"],
            "kubeconfig_path": kubeconfig_result["kubeconfig_path"],
            "control_plane_nodes": cluster_config["control_plane_nodes"],
            "worker_nodes": cluster_config.get("worker_nodes", [])
        }
