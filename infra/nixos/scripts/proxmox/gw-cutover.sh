#!/usr/bin/env bash
# Switch the router from OPNSense (VM 100) to gw (VM 101). Runs on the Proxmox `router`
# node, on its own, so it doesn't need the internet or an agent while it works:
#
#   systemd-run --unit=gw-cutover /root/gw/gw-cutover.sh
#   journalctl -fu gw-cutover          # follow along
#
# 1. While OPNSense still runs: snapshot it, copy its DHCP leases and Tailscale
#    identity, and put them on gw's (stopped) disk. Any failure here changes nothing.
# 2. Shut OPNSense down cleanly (ends the PPPoE session properly) and start gw.
#    From here on, any failure or exit before success rolls back to OPNSense.
# 3. Wait up to $HEALTH_TIMEOUT seconds for gw to be healthy: PPPoE up, internet
#    from gw and from this host through gw, DNS on 192.168.1.1, Kea and Unbound running.
# 4. Healthy: gw starts on boot instead of OPNSense. Not healthy: roll back.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
. "$here/gw-lib.sh"

HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-600}
work=/root/gw/cutover-$(date +%Y%m%d-%H%M%S)
install -d -m 700 "$work"

log "preflight"
[ "$(qm status $OPN | awk '{print $2}')" = running ] || { log "OPNSense (VM $OPN) isn't running: refusing"; exit 1; }
[ "$(qm status $GW | awk '{print $2}')" = stopped ] || { log "gw (VM $GW) must exist and be stopped: run gw-prepare.sh"; exit 1; }
qm config $GW | grep -qx 'name: gw' || { log "VM $GW isn't gw: refusing"; exit 1; }
# The leases and the Tailscale identity are read through OPNSense's guest agent, or,
# if it isn't answering, from the snapshot below (read-only, OPNSense keeps running).
agent=yes
qm agent $OPN ping 2>/dev/null || {
  agent=no
  log "OPNSense's guest agent isn't answering: will read its state from the snapshot instead"
}

log "snapshot OPNSense (pre-gw-cutover)"
qm delsnapshot $OPN pre-gw-cutover 2>/dev/null || true
qm snapshot $OPN pre-gw-cutover --description "before switching to gw ($(date -I))"

# Kea's lease file cleanup keeps most leases in .1/.2; the main file only has the
# changes since. Kea loads all three at startup.
# OPNSense's disk is UFS2 with /var on the root partition (p3).
copy_from_snapshot() {
  local lv loop mnt rc=0
  lv=snap_vm-${OPN}-disk-0_pre-gw-cutover
  lvchange -ay -K "pve/$lv"
  loop=$(losetup -r -fP --show "/dev/pve/$lv")
  udevadm settle
  mnt=$(mktemp -d)
  if mount -t ufs -o ro,ufstype=ufs2 "${loop}p3" "$mnt"; then
    for f in kea-leases4.csv kea-leases4.csv.1 kea-leases4.csv.2; do
      if [ -s "$mnt/var/db/kea/$f" ]; then
        cp "$mnt/var/db/kea/$f" "$work/dhcp4.leases${f#kea-leases4.csv}" || rc=1
      fi
    done
    cp "$mnt/var/db/tailscale/tailscaled.state" "$work/tailscaled.state" || rc=1
    umount "$mnt"
  else
    rc=1
  fi
  rmdir "$mnt"
  losetup -d "$loop"
  lvchange -an "pve/$lv"
  return $rc
}

if [ $agent = yes ]; then
  log "copy DHCP leases and Tailscale state from OPNSense (guest agent)"
  for f in kea-leases4.csv kea-leases4.csv.1 kea-leases4.csv.2; do
    if guest_sh $OPN "test -s /var/db/kea/$f"; then
      guest_cat $OPN /var/db/kea/$f >"$work/dhcp4.leases${f#kea-leases4.csv}"
    fi
  done
  guest_cat $OPN /var/db/tailscale/tailscaled.state >"$work/tailscaled.state"
else
  log "copy DHCP leases and Tailscale state from OPNSense (its pre-gw-cutover snapshot, read-only)"
  copy_from_snapshot || { log "couldn't read OPNSense's state from the snapshot: refusing; nothing changed"; exit 1; }
fi
chmod 600 "$work"/*
python3 -m json.tool "$work/tailscaled.state" >/dev/null || { log "copied tailscaled.state isn't valid JSON: refusing"; exit 1; }
ls "$work"/dhcp4.leases* >/dev/null || { log "no Kea lease files copied: refusing"; exit 1; }
log "  $(cat "$work"/dhcp4.leases* | grep -c '^192\.') lease lines in $(ls "$work"/dhcp4.leases* | wc -l) files, tailscale state $(wc -c <"$work/tailscaled.state") bytes"

# Kea runs as a systemd DynamicUser: its state directory is /var/lib/private/kea.
# systemd re-owns that directory only when its owner is wrong, so the lease files
# must get the directory's owner, or Kea can't open them and DHCP doesn't start.
install_state() {
  local kea=$ROOT/var/lib/private/kea f
  install -d -m 700 "$ROOT/var/lib/private" &&
    install -d -m 755 "$kea" &&
    rm -f "$kea"/dhcp4.leases* || return 1
  for f in "$work"/dhcp4.leases*; do
    install -m 600 -o "$(stat -c %u "$kea")" -g "$(stat -c %g "$kea")" "$f" "$kea/$(basename "$f")" || return 1
  done
  install -d -m 700 "$ROOT/var/lib/tailscale" &&
    install -m 600 "$work/tailscaled.state" "$ROOT/var/lib/tailscale/tailscaled.state"
}
log "install leases and Tailscale state on gw's disk"
with_gw_root install_state

# From here, leaving without success means rolling back to OPNSense.
success=
rollback_unless_done() {
  [ -n "$success" ] && return
  log "switchover didn't complete: rolling back to OPNSense"
  "$here/gw-rollback.sh" || true
}
trap rollback_unless_done EXIT

log "shut down OPNSense"
qm shutdown $OPN --timeout 180 || { log "  clean shutdown timed out; stopping"; qm stop $OPN; }

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
until healthy; do
  if [ $SECONDS -ge $deadline ]; then
    log "gw not healthy after ${HEALTH_TIMEOUT}s; last checks:"
    guest_sh $GW 'ip -4 addr show ppp0; systemctl --failed --no-legend; journalctl -u pppd-wan -n 15 --no-pager' 60 | sed 's/^/  /' || log "  (guest agent not answering)"
    exit 1 # the EXIT trap rolls back
  fi
  sleep 10
done

log "gw is healthy: PPPoE up, internet and DNS work"
qm set $OPN --onboot 0
qm set $GW --onboot 1 --startup order=1
success=1

# Tailscale is remote access, not internet: report it, but don't roll back over it.
for _ in $(seq 1 12); do
  ts=$(guest_sh $GW 'tailscale status --json | grep -o "\"BackendState\": *\"[A-Za-z]*\"" | head -1' || true)
  case $ts in *Running*) break ;; esac
  sleep 5
done
case $ts in
  *Running*) log "Tailscale: running as the old opnsense node" ;;
  *) log "WARNING: Tailscale isn't running (${ts:-no answer}); remote access via Tailscale is down" ;;
esac

shred -u "$work"/* && rmdir "$work"
log "done. Rollback any time: $here/gw-rollback.sh"
