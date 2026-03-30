#!/usr/bin/env bash
set -euo pipefail

# k8s-node-affinity-auditor.sh
# Detect workloads that don't specify node affinity/nodeSelector (may run on any node).

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans Pods, Deployments, StatefulSets, DaemonSets, ReplicaSets, ReplicationControllers, Jobs, CronJobs.
  - Reports objects where spec.template.spec.nodeSelector is empty and spec.template.spec.affinity.nodeAffinity is missing.

Examples:
  bash/k8s-node-affinity-auditor.sh
  bash/k8s-node-affinity-auditor.sh --output json
  bash/k8s-node-affinity-auditor.sh --output json --no-fail
EOF
}

OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="${2:-}"; shift 2
      ;;
    --no-fail)
      NO_FAIL=true; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage; exit 2
      ;;
  esac
done

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "json" ]]; then
  echo "--output must be text or json" >&2
  exit 2
fi

for cmd in kubectl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required" >&2
    exit 3
  fi
done

resources=(pods deployments daemonsets statefulsets replicasets replicationcontrollers jobs cronjobs)
all_json='{"items":[]} '
for res in "${resources[@]}"; do
  output="$(kubectl get "$res" --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
  all_json="$(jq -s '.[0] * {items:(.[0].items + .[1].items)}' <(echo "$all_json") <(echo "$output"))"
done

findings="$(jq -c '
  .items[]?
  | {kind:.kind, namespace:.metadata.namespace, name:.metadata.name, spec:(.spec.template.spec // .spec)}
  | select((.spec.nodeSelector == null or .spec.nodeSelector | length == 0) and (.spec.affinity.nodeAffinity == null))
  | {kind:.kind, namespace:.namespace, name:.name}
' <<< "$all_json")"

result="$(jq -n --argjson findings "[$findings]" '{no_node_affinity_or_selector:$findings}')"
count="$(jq '.no_node_affinity_or_selector | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No workloads lacking node affinity/resource locale constraints found."
  else
    echo "Workloads without node affinity or nodeSelector (count=$count):"
    jq -r '.no_node_affinity_or_selector[] | "- \(.kind) \(.namespace)/\(.name)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
