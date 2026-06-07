#!/usr/bin/env python3
"""Post-process talhelper configs: remove LinkConfig documents.

In Talos v1.12, a LinkConfig document takes EXCLUSIVE control of the interface,
overriding machine.network.interfaces entirely. Since talhelper generates LinkConfig
without routes, the default route is lost.

Fix: remove all LinkConfig documents. machine.network.interfaces already has the
complete correct config (addresses + routes + VIP) in the old v1alpha1 format,
which Talos v1.12 still supports and processes correctly.
"""
import os, glob

config_dir = os.path.join(os.path.dirname(__file__), 'clusterconfig')
for config_file in glob.glob(os.path.join(config_dir, 'kuberseni-*.yaml')):
    with open(config_file) as f:
        content = f.read()
    
    if 'kind: LinkConfig' not in content:
        continue
    
    # Remove LinkConfig documents entirely
    docs = content.split('---')
    filtered = [d for d in docs if not (d.strip() and 'kind: LinkConfig' in d)]
    
    if len(filtered) < len(docs):
        with open(config_file, 'w') as f:
            f.write('---'.join(filtered))
        removed = len(docs) - len(filtered)
        print(f"Fixed {os.path.basename(config_file)}: removed {removed} LinkConfig doc(s)")

print("Done")
