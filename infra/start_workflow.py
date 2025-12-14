#!/usr/bin/env python3
"""
Temporal Workflow Starter for Talos Cluster Management

Usage examples:
  # Full cluster install (Proxmox VMs + Talos bootstrap)
  python start_workflow.py --operation full --cluster-name kuberseni-cluster
  
  # Just bootstrap Talos on existing VMs
  python start_workflow.py --operation bootstrap --cluster-name kuberseni-cluster \
    --control-plane-nodes '[{"name":"control-plane-1","ip":"192.168.1.146"}]'
  
  # Upgrade existing cluster
  python start_workflow.py --operation upgrade --cluster-name kuberseni-cluster \
    --target-version v1.11.6 \
    --control-plane-nodes '[{"name":"control-plane-1","ip":"192.168.1.146"}]'
"""

import asyncio
import json
import argparse
import os
from temporalio.client import Client
from workflows.main import MainWorkflow


async def start_workflow(config: dict):
    """Start a workflow with the given configuration"""
    # Use temporal service name when running in container, localhost when running locally
    temporal_address = os.getenv("TEMPORAL_TARGET", "localhost:7233")
    client = await Client.connect(temporal_address)
    
    # Map operations to descriptive workflow names
    operation_names = {
        "install": "main",
        "bootstrap": "main", 
        "upgrade": "main",
        "destroy": "main",
        "full": "main"
    }
    
    operation = config.get("operation", "full")
    workflow_name = operation_names.get(operation, operation)
    workflow_id = f"{config['cluster_name']}-{workflow_name}"
    
    print(f"Starting workflow: {workflow_id}")
    print(f"Configuration: {json.dumps(config, indent=2)}")
    
    handle = await client.start_workflow(
        MainWorkflow.run,
        config,
        id=workflow_id,
        task_queue="talos-management"
    )
    
    print(f"Workflow started with ID: {handle.id}")
    print(f"Workflow URL: http://localhost:8090/namespaces/default/workflows/{handle.id}")
    print("\nWorkflow will wait for approvals. Use the Temporal UI or send signals to approve operations.")
    
    return handle


def parse_node_list(node_list_str: str):
    """Parse node list from JSON string"""
    if not node_list_str:
        return []
    try:
        return json.loads(node_list_str)
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid JSON for node list: {e}")


def main():
    parser = argparse.ArgumentParser(description="Start Talos cluster management workflows")
    parser.add_argument("--operation", required=True, 
                       choices=["install", "bootstrap", "upgrade", "destroy", "full"],
                       help="Operation to perform")
    parser.add_argument("--cluster-name", required=True,
                       help="Name of the cluster")
    parser.add_argument("--infra-path", default="./terraform",
                       help="Path to Terraform infrastructure")
    parser.add_argument("--target-version",
                       help="Target Talos version (for upgrades)")
    parser.add_argument("--control-plane-nodes", 
                       help='JSON list of control plane nodes [{"name":"...","ip":"..."}]')
    parser.add_argument("--worker-nodes",
                       help='JSON list of worker nodes [{"name":"...","ip":"..."}]')
    parser.add_argument("--skip-proxmox", action="store_true",
                       help="Skip Proxmox VM creation (for bootstrap-only)")
    parser.add_argument("--upgrade-strategy", choices=["rolling", "parallel"], default="rolling",
                       help="Upgrade strategy for worker nodes")
    parser.add_argument("--wait-between-nodes", type=int, default=120,
                       help="Seconds to wait between node upgrades")
    
    args = parser.parse_args()
    
    # Build configuration
    config = {
        "operation": args.operation,
        "cluster_name": args.cluster_name,
        "infra_path": args.infra_path,
        "skip_proxmox": args.skip_proxmox,
        "upgrade_strategy": args.upgrade_strategy,
        "wait_between_nodes": args.wait_between_nodes
    }
    
    if args.target_version:
        config["target_talos_version"] = args.target_version
    
    if args.control_plane_nodes:
        config["control_plane_nodes"] = parse_node_list(args.control_plane_nodes)
    
    if args.worker_nodes:
        config["worker_nodes"] = parse_node_list(args.worker_nodes)
    
    # For bootstrap-only operations, we need cluster_config
    if args.operation == "bootstrap" and not args.skip_proxmox:
        if not args.control_plane_nodes:
            raise ValueError("control_plane_nodes required for bootstrap operation")
        
        cluster_config = {
            "cluster_name": args.cluster_name,
            "control_plane_nodes": config["control_plane_nodes"],
            "worker_nodes": config.get("worker_nodes", [])
        }
        
        if args.target_version:
            cluster_config["talos_version"] = args.target_version
            
        config["cluster_config"] = cluster_config
    
    # Start the workflow
    asyncio.run(start_workflow(config))


if __name__ == "__main__":
    main()
