#!/usr/bin/env bash
set -euo pipefail

# k8s-single-replica-workload-auditor.sh
# Detect workloads (Deployment/StatefulSet/ReplicaSet) with replicas <= 1.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans Deployments, StatefulSets, ReplicaSets for replica count <= 1.
  - Useful to catch low availability/workload misconfiguration.

Examples:
  bash/k8s-single-replica-workload-auditor.sh
  bash/k8s-single-replica-workload-auditor.sh --output json
  bash/k8s-single-replica-workload-auditor.sh --output json --no-fail
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

kinds=(deployments statefulsets replicasets)
all_json='{"items":[]} '
for kind in "${kinds[@]}"; do
  chunk="$(kubectl get "$kind" --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
  all_json="$(jq -s '.[0] * {items:(.[0].items + .[1].items)}' <(echo "$all_json") <(echo "$chunk"))"
done

findings="$(jq -c '
  .items[]?
  | {kind:.kind, name:.metadata.name, namespace:.metadata.namespace, replicas:(.spec.replicas // 1)}
  | select(.replicas <= 1)
' <<< "$all_json")"

result="$(jq -n --argjson findings "[$findings]" '{single_replica_workloads:$findings}')"
count="$(jq '.single_replica_workloads | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No single-replica (<=1) workloads found.";
  else
    echo "Workloads with replica count <= 1 (count=$count):"
    jq -r '.single_replica_workloads[] | "- \(.kind) \(.namespace)/\(.name) replicas=\(.replicas)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
