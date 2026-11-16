#!/usr/bin/env bash
# Deploy a host from a commit on origin/main, with a dead-man switch.
#
#   infra/nixos/scripts/deploy.sh <host> [rev]      # rev defaults to origin/main
#
# gw only takes commits on origin/main. gw-staging takes any pushed commit, so a PR
# can be tried on it before merge.
#
# Needs only ssh here: the host builds its own closure from GitHub. Steps:
#   1. `nixos-rebuild build`: fetch and build. Changes nothing; a failure just exits.
#   2. Arm a timer on the host that reboots it in $DEADMAN (default 10min).
#   3. `nixos-rebuild test`: activate the new config, leave the bootloader alone.
#   4. Confirm from here: the host is still reachable over ssh and can reach the internet.
#   5. Confirmed: disarm the timer and `nixos-rebuild switch` (make it the boot default).
#      Not confirmed: the timer reboots it into the last switched generation.
set -euo pipefail

host=${1:?usage: deploy.sh <host> [rev]}
case $host in
  gw) addr=192.168.1.1 ;;
  gw-staging) addr=${GW_STAGING_ADDR:?set GW_STAGING_ADDR to gw-staging\'s WAN address} ;;
  *) echo "unknown host: $host" >&2; exit 1 ;;
esac

git fetch -q origin
rev=$(git rev-parse "${2:-origin/main}")
if [ "$host" != gw-staging ] && ! git merge-base --is-ancestor "$rev" origin/main; then
  echo "$rev is not on origin/main: review and merge it first" >&2
  exit 1
fi
flake="github:Arsenikki/kuberseni-gitops/$rev?dir=infra/nixos#$host"
ssh=(ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$addr")

# Transient units don't get the system PATH. The memory cap keeps an evaluation of
# nixpkgs from pushing the router's own services (pppd, Kea) into OOM.
run_unit() {
  local unit=$1; shift
  "${ssh[@]}" "systemd-run --wait --pipe --collect --unit=$unit \
    -p MemoryHigh=1G -p MemoryMax=1400M \
    --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin --working-directory=/tmp $*"
}

# What "still works" means before a change is made permanent. The ping from here
# goes through the router when deploying gw.
checks="! systemctl is-active -q deploy-test && test -e /run/deploy-ok \
  && ping -c1 -W3 1.1.1.1 >/dev/null \
  && systemctl is-active -q nftables kea-dhcp4-server unbound \
  && [ -z \"\$(systemctl --failed --no-legend)\" ]"

echo "building $rev on $host"
if ! run_unit deploy-build nixos-rebuild build --flake "'$flake'"; then
  echo "build failed; nothing changed on $host" >&2
  exit 1
fi

echo "arming dead-man switch on $host (${DEADMAN:-10min})"
"${ssh[@]}" "systemctl stop deploy-deadman.timer 2>/dev/null || true
  systemd-run --on-active='${DEADMAN:-10min}' --unit=deploy-deadman systemctl reboot"

# In its own unit, so it finishes even if the change drops this ssh session.
echo "nixos-rebuild test $rev"
"${ssh[@]}" "rm -f /run/deploy-ok /run/deploy-failed" &&
  run_unit deploy-test sh -c "\"if nixos-rebuild test --flake '$flake'; then touch /run/deploy-ok; else touch /run/deploy-failed; fi\"" ||
  echo "ssh session ended early; checking the host" >&2

for _ in $(seq 1 30); do
  state=$("${ssh[@]}" "if systemctl is-active -q deploy-test; then echo running
    elif $checks; then echo ok
    elif test -e /run/deploy-failed; then echo failed
    else echo unknown; fi" 2>/dev/null || echo unreachable)
  case $state in
    ok)
      if [ "$host" = gw ] && ! ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
        echo "gw is up but this machine can't reach the internet through it; not confirming" >&2
        sleep 10
        continue
      fi
      "${ssh[@]}" "systemctl stop deploy-deadman.timer" &&
        run_unit deploy-switch nixos-rebuild switch --flake "'$flake'"
      echo "deployed $rev to $host"
      exit 0
      ;;
    failed)
      echo "activation failed on $host: the dead-man timer will reboot it into the previous generation" >&2
      exit 1
      ;;
  esac
  sleep 10
done

echo "$host not confirmed: it reboots into the previous generation when the dead-man timer fires" >&2
exit 1
