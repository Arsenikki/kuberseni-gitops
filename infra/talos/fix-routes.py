#!/usr/bin/env python3
"""No-op: Talos v1.13 handles LinkConfig routes with gateway-only (no destination) correctly,
creating a default route as expected. No post-processing needed."""
import glob, os

config_dir = os.path.join(os.path.dirname(__file__), 'clusterconfig')
count = len(glob.glob(os.path.join(config_dir, 'kuberseni-*.yaml')))
print(f"Done ({count} configs, no changes needed)")
