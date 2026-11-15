#!/usr/bin/env bash
# Deploy a host from a commit on origin/main, with a dead-man switch.
#
#   infra/nixos/scripts/deploy.sh <host> [rev]      # rev defaults to origin/main
#
# Needs only ssh here: the host builds its own closure from GitHub. Steps:
#   1. Arm a timer on the host that reboots it in $DEADMAN (default 10min).
#   2. `nixos-rebuild test`: activate the new config, leave the bootloader alone.
#   3. Confirm from here: the host is still reachable over ssh and can reach the internet.
#   4. Confirmed: disarm the timer and `nixos-rebuild switch` (make it the boot default).
#      Not confirmed: the timer reboots it into the last switched generation.
set -euo pipefail

host=${1:?usage: deploy.sh <host> [rev]}
case $host in
  gw) addr=192.168.1.1 ;;
  gw-staging) addr=${GW_STAGING_ADDR:?set GW_STAGING_ADDR to gw-staging\'s WAN address} ;;
  *) echo "unknown host: $host" >&2; exit 1 ;;
esac

git fetch -q origin main
rev=$(git rev-parse "${2:-origin/main}")
if ! git merge-base --is-ancestor "$rev" origin/main; then
  echo "$rev is not on origin/main: review and merge it first" >&2
  exit 1
fi
flake="github:Arsenikki/kuberseni-gitops/$rev?dir=infra/nixos#$host"
ssh=(ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$addr")

echo "arming dead-man switch on $host (${DEADMAN:-10min})"
"${ssh[@]}" "systemctl stop deploy-deadman.timer 2>/dev/null || true
  systemd-run --on-active='${DEADMAN:-10min}' --unit=deploy-deadman systemctl reboot"

# In its own unit, so it finishes even if the change drops this ssh session.
echo "nixos-rebuild test $rev"
"${ssh[@]}" "rm -f /run/deploy-ok
  systemd-run --wait --pipe --collect --unit=deploy-test \
    sh -c \"nixos-rebuild test --flake '$flake' && touch /run/deploy-ok\"" ||
  echo "ssh exited non-zero (connection dropped or build failed); checking the host" >&2

for _ in $(seq 1 30); do
  if "${ssh[@]}" "! systemctl is-active -q deploy-test && test -e /run/deploy-ok && ping -c1 -W3 1.1.1.1 >/dev/null"; then
    "${ssh[@]}" "systemctl stop deploy-deadman.timer && nixos-rebuild switch --flake '$flake'"
    echo "deployed $rev to $host"
    exit 0
  fi
  sleep 10
done

echo "$host not confirmed: it reboots into the previous generation when the dead-man timer fires" >&2
exit 1
