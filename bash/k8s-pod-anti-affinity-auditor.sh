#!/usr/bin/env bash
set -euo pipefail

# k8s-pod-anti-affinity-auditor.sh
# Detect workloads with pod templates missing podAntiAffinity (anti-affinity) settings.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Checks Deployments, StatefulSets, DaemonSets, ReplicaSets, ReplicationControllers, Jobs, CronJobs
    for `spec.template.spec.affinity.podAntiAffinity` presence.
  - Findings indicate potential missing topology isolation policy for pods.

Examples:
  bash/k8s-pod-anti-affinity-auditor.sh
  bash/k8s-pod-anti-affinity-auditor.sh --output json
  bash/k8s-pod-anti-affinity-auditor.sh --output json --no-fail
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

# Collect resources safely (cluster may not support some types).
declare -a kinds=(deployments statefulsets daemonsets replicasets replicationcontrollers jobs cronjobs)
resources_sum='{"items":[]}'
for kind in "${kinds[@]}"; do
  items_json="$(kubectl get "$kind" --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
  resources_sum="$(jq -s '.[0] * {items:(.[0].items + .[1].items)}' <(echo "$resources_sum") <(echo "$items_json"))"
done

findings="$(jq -c '.items[]? | select(.spec.template.spec.affinity.podAntiAffinity == null) | {kind:.kind, namespace:.metadata.namespace, name:.metadata.name, apiVersion:.apiVersion, labelSelector:(.spec.selector.matchLabels // .spec.selector // {}), hasPodAffinity:(.spec.template.spec.affinity.podAffinity != null)}' <<< "$resources_sum")"

result="$(jq -n --argjson finds "[$findings]" '{missing_podAntiAffinity:$finds}')"
count="$(jq '.missing_podAntiAffinity | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No workload templates missing podAntiAffinity found."
  else
    echo "Workload templates missing podAntiAffinity (count=$count):"
    jq -r '.missing_podAntiAffinity[] | "- \(.kind) \(.namespace)/\(.name) hasPodAffinity=\(.hasPodAffinity) selector=\(.labelSelector)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
