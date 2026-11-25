# Shared by the gw-*.sh scripts, which run as root on the Proxmox `router` node.
# shellcheck shell=bash

OPN=${OPN:-100} # OPNSense
GW=${GW:-101}   # gw (NixOS)

log() { echo "[$(date +%T)] $*"; }

# Read a file from inside a running VM via the QEMU guest agent. Fails unless the
# command finished, succeeded and the output wasn't truncated.
guest_cat() {
  qm guest exec "$1" --timeout 30 -- cat "$2" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("exited") or d.get("exitcode") != 0 or d.get("out-truncated"):
    sys.exit("guest exec of cat %s failed: %s" % (sys.argv[1], d.get("err-data", d)))
sys.stdout.write(d.get("out-data", ""))' "$2"
}

# Run a shell command inside a VM via the guest agent; exit status is the command's.
# NixOS's guest agent runs commands without a PATH, hence /bin/sh and the export.
guest_sh() {
  qm guest exec "$1" --timeout "${3:-30}" -- /bin/sh -c \
    "export PATH=/run/current-system/sw/bin:/run/wrappers/bin:/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin; $2" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(255)
sys.stdout.write(d.get("out-data", ""))
sys.exit(d.get("exitcode", 255))'
}

# Copy files into gw's root filesystem while the VM is stopped:
#   with_gw_root <command...>   runs the command with $ROOT set to the mounted root.
# The command runs in an || context, where set -e is off: chain its steps with &&.
with_gw_root() {
  [ "$(qm status $GW | awk '{print $2}')" = stopped ] || { log "VM $GW must be stopped"; return 1; }
  local disk loop part rc=0
  disk=$(pvesm path "$(qm config $GW | sed -n 's/^virtio0: \([^,]*\).*/\1/p')")
  loop=$(losetup -fP --show "$disk")
  udevadm settle
  part=$(blkid -o device -t LABEL=nixos "$loop"p* 2>/dev/null | head -1)
  if [ -z "$part" ]; then
    log "no partition labelled nixos on $disk"
    losetup -d "$loop"
    return 1
  fi
  ROOT=$(mktemp -d)
  if mount "$part" "$ROOT"; then
    "$@" || rc=$?
    umount "$ROOT"
  else
    rc=1
  fi
  rmdir "$ROOT"
  losetup -d "$loop"
  return $rc
}
