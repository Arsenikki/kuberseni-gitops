#!/usr/bin/env bash
# Checks that the rest of the cluster can take a node's pods before it's drained
# (Talos upgrade, reboot). Compares the CPU/memory *requests* of the pods that would
# be evicted with the free requestable capacity on the other schedulable, untainted
# nodes, which is what the scheduler will use to place them.
#
# Why: the 2026-11-23 worker-01 upgrade moved everything onto worker-02, which ended
# up 89% CPU / 98% memory requested; probes timed out and ~13 pods crash-looped.
#
# Usage: talos-drain-check.sh <node>   (FORCE=1 turns a failure into a warning)
# Uses $KUBECONFIG if it works, else a 10-minute admin kubeconfig from `topf kubeconfig`
# (run from infra/talos).
set -euo pipefail

node="${1:?usage: $0 <node>}"
warn_pct="${WARN_PCT:-85}" # descheduler's requests target (cluster/apps/descheduler)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! kubectl get --raw /readyz --request-timeout=5s >/dev/null 2>&1; then
  topf kubeconfig --validity 10m >"$tmp/kubeconfig"
  export KUBECONFIG="$tmp/kubeconfig"
fi

kubectl get nodes -o json >"$tmp/nodes.json"
kubectl get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed -o json >"$tmp/pods.json"

jq -rn --arg node "$node" --argjson warn "$warn_pct" \
  --slurpfile n "$tmp/nodes.json" --slurpfile p "$tmp/pods.json" '
  def cpu: if . == null then 0 elif endswith("m") then (.[:-1] | tonumber) / 1000 else tonumber end;
  def mem:
    if . == null then 0 else
      (capture("^(?<n>[0-9.e+]+)(?<u>[A-Za-z]*)$")) as $m
      | ($m.n | tonumber) * ({"": 1, "k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
          "Ki": 1024, "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776}[$m.u] // 1)
    end;
  def req($f): [.spec.containers[].resources.requests[$f] // null | if $f == "cpu" then cpu else mem end] | add // 0;
  def gib: . / 1073741824 * 10 | round / 10;
  def pct(a; b): if b > 0 then a / b * 100 | round else 0 end;

  $n[0] as $nodes | $p[0] as $pods
  | ($nodes.items | map(select(.metadata.name == $node)) | first) as $target
  | if $target == null then error("node \($node) not found") else . end
  # Pods that the drain evicts: everything on the node except DaemonSet and static pods.
  | [$pods.items[] | select(.spec.nodeName == $node)
      | select(([.metadata.ownerReferences[]?.kind] | index("DaemonSet")) == null)
      | select(.metadata.annotations["kubernetes.io/config.mirror"] == null)] as $moving
  | {cpu: ($moving | map(req("cpu")) | add // 0), mem: ($moving | map(req("memory")) | add // 0)} as $need
  # Where they can go: schedulable nodes without NoSchedule/NoExecute taints.
  | [$nodes.items[] | select(.metadata.name != $node)
      | select(.spec.unschedulable != true)
      | select([.spec.taints[]? | select(.effect != "PreferNoSchedule")] | length == 0)
      | .metadata.name as $n
      | {name: $n,
         cpu: (.status.allocatable.cpu | cpu), mem: (.status.allocatable.memory | mem),
         ucpu: ([$pods.items[] | select(.spec.nodeName == $n) | req("cpu")] | add // 0),
         umem: ([$pods.items[] | select(.spec.nodeName == $n) | req("memory")] | add // 0)}] as $dest
  | ($dest | map(.cpu) | add // 0) as $tcpu | ($dest | map(.mem) | add // 0) as $tmem
  | ($dest | map(.ucpu) | add // 0) as $ucpu | ($dest | map(.umem) | add // 0) as $umem
  | ($tcpu - $ucpu) as $fcpu | ($tmem - $umem) as $fmem
  | pct($ucpu + $need.cpu; $tcpu) as $after_cpu | pct($umem + $need.mem; $tmem) as $after_mem
  | [
      "Draining \($node) evicts \($moving | length) pods requesting \($need.cpu * 100 | round / 100) CPU / \($need.mem | gib) GiB.",
      "Destination nodes: \(if ($dest | length) == 0 then "none" else ($dest | map(.name) | join(", ")) end)",
      ($dest[] | "  \(.name): \(pct(.ucpu; .cpu))% CPU / \(pct(.umem; .mem))% memory requested now, free \((.cpu - .ucpu) * 100 | round / 100) CPU / \((.mem - .umem) | gib) GiB"),
      "After the drain they would be at \($after_cpu)% CPU / \($after_mem)% memory requested (combined).",
      (if ($dest | length) == 0 or $need.cpu > $fcpu or $need.mem > $fmem then
         "FAIL: not enough free requests on the remaining nodes; pods would stay Pending."
       elif $after_cpu > $warn or $after_mem > $warn then
         "FAIL: the remaining nodes would be above \($warn)% requested; expect probe timeouts and crash-loops."
       else "OK" end)
    ] | .[]
' | tee /dev/stderr | tail -1 | grep -q '^OK$' && exit 0

if [ "${FORCE:-0}" = "1" ]; then
  echo "FORCE=1: continuing anyway." >&2
  exit 0
fi
echo "Free up capacity first (scale down non-essential apps), or rerun with FORCE=1." >&2
exit 1
