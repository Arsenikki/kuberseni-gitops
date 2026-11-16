#!/usr/bin/env bash
# Switch the router from OPNSense (VM 100) to gw (VM 101). Runs on the Proxmox `router`
# node, on its own, so it doesn't need the internet or an agent while it works:
#
#   systemd-run --unit=gw-cutover /root/gw/gw-cutover.sh
#   journalctl -fu gw-cutover          # follow along
#
# 1. Snapshot OPNSense, and copy its DHCP leases and Tailscale identity.
# 2. Shut OPNSense down cleanly (ends the PPPoE session properly).
# 3. Put the leases and Tailscale state onto gw's disk, then start gw.
# 4. Wait up to $HEALTH_TIMEOUT seconds for gw to be healthy: PPPoE up, internet
#    from gw and from this host through gw, DNS on 192.168.1.1, Kea and Unbound running.
# 5. Healthy: gw starts on boot instead of OPNSense. Not healthy: roll back to OPNSense.
set -euo pipefail
. "$(dirname "$0")/gw-lib.sh"

HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-600}
work=/root/gw/cutover-$(date +%Y%m%d-%H%M%S)
install -d -m 700 "$work"

log "preflight"
[ "$(qm status $OPN | awk '{print $2}')" = running ] || { log "OPNSense (VM $OPN) isn't running: refusing"; exit 1; }
[ "$(qm status $GW | awk '{print $2}')" = stopped ] || { log "gw (VM $GW) must exist and be stopped: run gw-prepare.sh"; exit 1; }

log "snapshot OPNSense (pre-gw-cutover)"
qm delsnapshot $OPN pre-gw-cutover 2>/dev/null || true
qm snapshot $OPN pre-gw-cutover --description "before switching to gw ($(date -I))"

log "copy DHCP leases and Tailscale state from OPNSense"
guest_cat $OPN /var/db/kea/kea-leases4.csv >"$work/dhcp4.leases"
guest_cat $OPN /var/db/tailscale/tailscaled.state >"$work/tailscaled.state"
chmod 600 "$work"/*
log "  $(($(wc -l <"$work/dhcp4.leases") - 1)) lease lines, tailscale state $(wc -c <"$work/tailscaled.state") bytes"

log "shut down OPNSense"
qm shutdown $OPN --timeout 180 || { log "  clean shutdown timed out; stopping"; qm stop $OPN; }

# Kea runs as a systemd DynamicUser: its state directory is /var/lib/private/kea.
# systemd re-owns that directory only when its owner is wrong, so the lease file must
# get the directory's owner, or Kea can't open it and DHCP doesn't start.
install_state() {
  local kea=$ROOT/var/lib/private/kea
  install -d -m 700 "$ROOT/var/lib/private"
  install -d -m 755 "$kea"
  install -m 600 -o "$(stat -c %u "$kea")" -g "$(stat -c %g "$kea")" "$work/dhcp4.leases" "$kea/dhcp4.leases"
  install -d -m 700 "$ROOT/var/lib/tailscale"
  install -m 600 "$work/tailscaled.state" "$ROOT/var/lib/tailscale/tailscaled.state"
}
log "install leases and Tailscale state on gw's disk"
with_gw_root install_state

log "start gw"
qm start $GW

# This host's resolv.conf points at 192.168.1.1, so getent checks gw's Unbound.
healthy() {
  guest_sh $GW 'ip -4 addr show ppp0 | grep -q inet' &&
    guest_sh $GW 'ping -c1 -W3 1.1.1.1 >/dev/null' &&
    guest_sh $GW 'systemctl is-active -q kea-dhcp4-server unbound' &&
    ping -c1 -W3 1.1.1.1 >/dev/null &&
    getent ahostsv4 example.com >/dev/null
}

deadline=$((SECONDS + HEALTH_TIMEOUT))
while [ $SECONDS -lt $deadline ]; do
  if healthy; then
    log "gw is healthy: PPPoE up, internet and DNS work"
    qm set $OPN --onboot 0
    qm set $GW --onboot 1 --startup order=1
    log "  Tailscale: $(guest_sh $GW 'tailscale status --json | grep -o "\"BackendState\": *\"[A-Za-z]*\"" | head -1' || echo unknown)"
    log "done. Rollback any time: $(dirname "$0")/gw-rollback.sh"
    exit 0
  fi
  sleep 10
done

log "gw not healthy after ${HEALTH_TIMEOUT}s; last checks:"
guest_sh $GW 'ip -4 addr show ppp0; systemctl --failed --no-legend; journalctl -u pppd-wan -n 15 --no-pager' 60 | sed 's/^/  /' || log "  (guest agent not answering)"
log "rolling back to OPNSense"
exec "$(dirname "$0")/gw-rollback.sh"
