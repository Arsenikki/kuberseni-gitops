#!/usr/bin/env bash
# Go back to OPNSense: stop gw (VM 101), start OPNSense (VM 100).
# Run on the Proxmox `router` node, e.g. from the web UI: router > Shell.
#
#   /root/gw/gw-rollback.sh
set -euo pipefail
. "$(dirname "$0")/gw-lib.sh"

log "stopping gw (VM $GW)"
qm shutdown $GW --timeout 60 2>/dev/null || qm stop $GW
qm set $GW --onboot 0
qm set $OPN --onboot 1

log "starting OPNSense (VM $OPN)"
qm start $OPN
for _ in $(seq 1 60); do
  if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
    log "internet is back through OPNSense"
    exit 0
  fi
  sleep 5
done
log "OPNSense started, but no internet after 5 minutes: check the OPNSense console (qm terminal $OPN, or the web UI)"
exit 1
