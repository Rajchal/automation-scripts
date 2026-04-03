#!/usr/bin/env bash
set -euo pipefail

# k8s-workload-labels-auditor.sh
# Detect workloads missing standard app.kubernetes.io labels.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans Deployments, StatefulSets, DaemonSets, ReplicaSets, ReplicationControllers, Jobs, and CronJobs.
  - Flags workloads missing app.kubernetes.io/name or app.kubernetes.io/instance labels on the workload object.

Examples:
  bash/k8s-workload-labels-auditor.sh
  bash/k8s-workload-labels-auditor.sh --output json
  bash/k8s-workload-labels-auditor.sh --output json --no-fail
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

kinds=(deployments statefulsets daemonsets replicasets replicationcontrollers jobs cronjobs)
all_json='{"items":[]}'
for kind in "${kinds[@]}"; do
  chunk="$(kubectl get "$kind" --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
  all_json="$(jq -s '.[0] * {items:(.[0].items + .[1].items)}' <(echo "$all_json") <(echo "$chunk"))"
done

findings="$(jq -c '
  .items[]?
  | {
      kind:.kind,
      namespace:.metadata.namespace,
      name:.metadata.name,
      labels:(.metadata.labels // {})
    }
  | select((.labels["app.kubernetes.io/name"] // "") == "" or (.labels["app.kubernetes.io/instance"] // "") == "")
  | {
      kind,
      namespace,
      name,
      missing:[
        (if (.labels["app.kubernetes.io/name"] // "") == "" then "app.kubernetes.io/name" else empty end),
        (if (.labels["app.kubernetes.io/instance"] // "") == "" then "app.kubernetes.io/instance" else empty end)
      ]
    }
' <<< "$all_json")"

result="$(jq -n --argjson findings "[$findings]" '{workloads_missing_standard_labels:$findings}')"
count="$(jq '.workloads_missing_standard_labels | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No workloads missing standard labels found."
  else
    echo "Workloads missing standard labels (count=$count):"
    jq -r '.workloads_missing_standard_labels[] | "- \(.kind) \(.namespace)/\(.name) missing=\(.missing | join(","))"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
