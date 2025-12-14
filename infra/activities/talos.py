import os
import subprocess
import tempfile
import json
from typing import Dict, List
from temporalio import activity


def run_command(cmd: List[str], cwd=None, capture_output=False):
    """Execute a command with proper error handling"""
    result = subprocess.run(
        cmd, 
        cwd=cwd, 
        check=True, 
        capture_output=capture_output,
        text=True
    )
    return result.stdout if capture_output else None


@activity.defn
async def generate_machine_configs(cluster_config: Dict) -> Dict[str, str]:
    """Generate Talos machine configurations"""
    cluster_name = cluster_config["cluster_name"]
    cluster_endpoint = cluster_config["cluster_endpoint"]
    
    # Create temporary directory for configs
    with tempfile.TemporaryDirectory() as temp_dir:
        # Create patch file for QEMU guest agent and other enhancements
        patch_content = """
machine:
  features:
    rbac: true
    stableHostname: true
cluster:
  allowSchedulingOnControlPlanes: true
  network:
    cni:
      name: "none"
"""
        patch_file = f"{temp_dir}/patch.yaml"
        with open(patch_file, "w") as f:
            f.write(patch_content)
        
        # Generate configs with patch
        run_command([
            "talosctl", "gen", "config",
            cluster_name,
            cluster_endpoint,
            "--output-dir", temp_dir,
            "--install-disk", "/dev/vda",
            "--config-patch", f"@{patch_file}"
        ])
        
        # Read the generated configs
        with open(f"{temp_dir}/controlplane.yaml", "r") as f:
            controlplane_config = f.read()
        
        with open(f"{temp_dir}/worker.yaml", "r") as f:
            worker_config = f.read()
            
        return {
            "controlplane": controlplane_config,
            "worker": worker_config
        }


@activity.defn
async def apply_machine_config(config_data: Dict):
    """Apply machine configuration to a node"""
    node_ip = config_data["node_ip"]
    node_name = config_data["node_name"]
    config_type = config_data["config_type"]
    machine_config = config_data["machine_config"]
    
    activity.logger.info(f"Applying {config_type} config to {node_name} ({node_ip})")
    
    # Write config to temporary file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
        f.write(machine_config)
        config_file = f.name
    
    try:
        # Apply configuration
        run_command([
            "talosctl", "apply-config",
            "--insecure",
            "--nodes", node_ip,
            "--file", config_file
        ])
        activity.logger.info(f"Successfully applied config to {node_name}")
    finally:
        os.unlink(config_file)


@activity.defn
async def bootstrap_cluster(bootstrap_config: Dict):
    """Bootstrap the Talos cluster"""
    bootstrap_node_ip = bootstrap_config["bootstrap_node_ip"]
    cluster_name = bootstrap_config["cluster_name"]
    
    activity.logger.info(f"Bootstrapping cluster {cluster_name} on {bootstrap_node_ip}")
    
    # Set the talosctl endpoint first
    run_command([
        "talosctl", "config", "endpoint", bootstrap_node_ip
    ])
    
    # Bootstrap the cluster
    run_command([
        "talosctl", "bootstrap",
        "-n", bootstrap_node_ip,
        "-e", bootstrap_node_ip
    ])
    
    activity.logger.info(f"Cluster {cluster_name} bootstrapped successfully")


@activity.defn
async def wait_for_node_ready(node_config: Dict):
    """Wait for a node to be ready"""
    node_ip = node_config["node_ip"]
    node_name = node_config["node_name"]
    
    activity.logger.info(f"Waiting for {node_name} ({node_ip}) to be ready")
    
    # Check if we can reach the Talos API port and node is out of maintenance
    import socket
    import time
    
    max_attempts = 60  # 10 minutes with 10 second intervals
    for attempt in range(max_attempts):
        try:
            # First check if API is reachable
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5)
            result = sock.connect_ex((node_ip, 50000))
            sock.close()
            
            if result == 0:
                activity.logger.info(f"{node_name} Talos API is reachable, checking machine status...")
                
                # Now check if the node is out of maintenance mode
                try:
                    output = run_command([
                        "talosctl", "get", "machinestatus", 
                        "--nodes", node_ip, 
                        "--insecure",
                        "--output", "json"
                    ], capture_output=True)
                    
                    import json
                    status_data = json.loads(output)
                    if status_data and len(status_data) > 0:
                        stage = status_data[0].get("spec", {}).get("stage", "unknown")
                        activity.logger.info(f"{node_name} stage: {stage}")
                        
                        if stage != "maintenance":
                            activity.logger.info(f"{node_name} is out of maintenance mode")
                            break
                        else:
                            activity.logger.info(f"{node_name} still in maintenance mode, waiting...")
                    
                except Exception as e:
                    activity.logger.info(f"Failed to get machine status for {node_name}: {e}")
            else:
                activity.logger.info(f"Attempt {attempt + 1}: {node_name} API not reachable")
                
        except Exception as e:
            activity.logger.info(f"Attempt {attempt + 1}: {node_name} not ready yet - {e}")
        
        if attempt < max_attempts - 1:
            time.sleep(10)
    else:
        raise Exception(f"{node_name} did not become ready within 10 minutes")
    
    activity.logger.info(f"{node_name} is ready")


@activity.defn
async def get_kubeconfig(kubeconfig_config: Dict) -> Dict[str, str]:
    """Extract kubeconfig from the cluster"""
    control_plane_ip = kubeconfig_config["control_plane_ip"]
    cluster_name = kubeconfig_config["cluster_name"]
    
    # Create kubeconfig path
    kubeconfig_path = f"./kubeconfig-{cluster_name}"
    
    # Set the talosctl endpoint first
    run_command([
        "talosctl", "config", "endpoint", control_plane_ip
    ])
    
    # Generate kubeconfig
    run_command([
        "talosctl", "kubeconfig",
        kubeconfig_path,
        "--nodes", control_plane_ip
    ])
    
    return {"kubeconfig_path": kubeconfig_path}


@activity.defn
async def verify_cluster_health(health_config: Dict):
    """Verify cluster is healthy"""
    control_plane_ips = health_config["control_plane_ips"]
    
    activity.logger.info("Verifying cluster health")
    
    # Check each control plane node
    for ip in control_plane_ips:
        run_command([
            "talosctl", "health",
            "--nodes", ip,
            "--insecure"
        ])
    
    activity.logger.info("All nodes are healthy")


@activity.defn
async def upgrade_node(upgrade_config: Dict):
    """Upgrade a single Talos node"""
    node_ip = upgrade_config["node_ip"]
    node_name = upgrade_config["node_name"]
    talos_version = upgrade_config["talos_version"]
    
    activity.logger.info(f"Upgrading {node_name} ({node_ip}) to {talos_version}")
    
    run_command([
        "talosctl", "upgrade",
        "--nodes", node_ip,
        "--image", f"ghcr.io/siderolabs/talos:{talos_version}",
        "--preserve",
        "--insecure"
    ])
    
    activity.logger.info(f"{node_name} upgraded successfully")
