#!/usr/bin/env python3
"""Post-process talhelper generated configs to remove broken LinkConfig routes.

talhelper v3.x generates LinkConfig.routes without a 'network/destination' field,
which in Talos v1.12 overrides the correct machine.network.interfaces routes.
We remove routes from LinkConfig entirely since machine.network.interfaces handles routing.
"""
import sys, os, glob

config_dir = os.path.join(os.path.dirname(__file__), 'clusterconfig')
for config_file in glob.glob(os.path.join(config_dir, 'kuberseni-*.yaml')):
    with open(config_file) as f:
        content = f.read()
    
    if 'kind: LinkConfig' not in content:
        continue
    
    # Split into documents, remove routes from LinkConfig docs
    docs = content.split('---')
    fixed_docs = []
    changed = False
    for doc in docs:
        if doc.strip() and 'kind: LinkConfig' in doc:
            lines = doc.split('\n')
            # Remove routes section from LinkConfig
            result = []
            skip = False
            for line in lines:
                if line.strip().startswith('routes:'):
                    skip = True
                    changed = True
                    continue
                if skip and (line.startswith('  ') or line.startswith('\t') or not line.strip()):
                    if not line.strip():
                        skip = False  # end of routes block on empty line
                    continue
                skip = False
                result.append(line)
            fixed_docs.append('\n'.join(result))
        else:
            fixed_docs.append(doc)
    
    if changed:
        with open(config_file, 'w') as f:
            f.write('---'.join(fixed_docs))
        print(f"Fixed: {os.path.basename(config_file)}")

print("Done")
