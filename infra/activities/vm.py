import os
import subprocess
import json
from typing import Dict
from temporalio import activity


def run_command(cmd, cwd=None, capture_output=False, log_output=False, output_header=None):
    """
    Execute command with proper error handling and optional logging
    
    Args:
        cmd: Command to run as list
        cwd: Working directory
        capture_output: Whether to capture and return stdout
        log_output: Whether to log the output (useful for plans)
        output_header: Optional header to wrap the output with for logging
    """
    try:
        # Log the command being executed
        activity.logger.info(f"Executing: {' '.join(cmd)}")
        
        result = subprocess.run(
            cmd,
            cwd=cwd,
            check=True,
            capture_output=capture_output,
            text=True
        )
        
        # Handle output logging if requested
        if log_output and result.stdout:
            if output_header:
                activity.logger.info(f"=== {output_header} ===")
                activity.logger.info(result.stdout)
                activity.logger.info(f"=== END {output_header} ===")
            else:
                activity.logger.info(result.stdout)
        
        return result.stdout if capture_output else None
        
    except subprocess.CalledProcessError as e:
        error_msg = f"Command {' '.join(cmd)} failed with code {e.returncode}"
        if e.stdout:
            error_msg += f"\nSTDOUT: {e.stdout}"
        if e.stderr:
            error_msg += f"\nSTDERR: {e.stderr}"
        activity.logger.error(error_msg)
        raise Exception(error_msg) from e


@activity.defn
async def plan_proxmox_infrastructure(config: Dict):
    """Plan Proxmox infrastructure changes"""
    infra_path = config.get("infra_path", "./terraform")
    
    activity.logger.info(f"Planning Proxmox infrastructure in {infra_path}")
    
    # Initialize Terraform first
    run_command(["tofu", "init"], cwd=infra_path)
    
    # Run OpenTofu plan with logging
    output = run_command(["tofu", "plan"], cwd=infra_path, capture_output=True, 
                        log_output=True, output_header="TERRAFORM PLAN OUTPUT")
    
    activity.logger.info("Plan completed successfully - review the plan above before approving")
    return {"plan_output": output}


@activity.defn
async def apply_proxmox_infrastructure(config: Dict):
    """Apply Proxmox infrastructure changes"""
    infra_path = config.get("infra_path", "./terraform")
    
    activity.logger.info(f"Applying Proxmox infrastructure in {infra_path}")
    
    if not config.get("auto_approve", False):
        raise ValueError("auto_approve must be True for infrastructure apply")
    
    # Ensure Terraform is initialized
    run_command(["tofu", "init"], cwd=infra_path)
    
    # Show apply plan first
    run_command(["tofu", "plan"], cwd=infra_path, capture_output=True,
               log_output=True, output_header="TERRAFORM APPLY PLAN")
    
    # Run OpenTofu apply
    run_command(["tofu", "apply", "-auto-approve"], cwd=infra_path)
    activity.logger.info("Infrastructure applied successfully")


@activity.defn
async def get_terraform_outputs(config: Dict) -> Dict:
    """Extract Terraform outputs for cluster configuration"""
    infra_path = config.get("infra_path", "./terraform")
    
    activity.logger.info(f"Extracting Terraform outputs from {infra_path}")
    
    # Get outputs as JSON
    output = run_command(["tofu", "output", "-json"], cwd=infra_path, capture_output=True)
    outputs = json.loads(output)
    
    # Extract relevant information
    vm_info = outputs.get("vm_info", {}).get("value", {})
    control_plane_ips = outputs.get("control_plane_ips", {}).get("value", [])
    
    # Transform into cluster config format
    control_plane_nodes = []
    for vm_name, vm_data in vm_info.items():
        if vm_name.startswith("control-plane-"):
            control_plane_nodes.append({
                "name": vm_name,
                "ip": vm_data.get("ipv4_address"),
                "vm_id": vm_data.get("vm_id")
            })
    
    return {
        "control_plane_nodes": control_plane_nodes,
        "control_plane_ips": control_plane_ips,
        "vm_info": vm_info
    }


@activity.defn
async def destroy_proxmox_infrastructure(config: Dict):
    """Destroy Proxmox infrastructure"""
    infra_path = config.get("infra_path", "./terraform")
    
    activity.logger.info(f"Destroying Proxmox infrastructure in {infra_path}")
    
    if not config.get("auto_approve", False):
        raise ValueError("auto_approve must be True for infrastructure destroy")
    
    # Ensure Terraform is initialized
    run_command(["tofu", "init"], cwd=infra_path)
    
    # Show destroy plan first
    run_command(["tofu", "plan", "-destroy"], cwd=infra_path, capture_output=True,
               log_output=True, output_header="TERRAFORM DESTROY PLAN")
    
    # Run OpenTofu destroy
    run_command(["tofu", "destroy", "-auto-approve"], cwd=infra_path)
    activity.logger.info("Infrastructure destroyed successfully")
