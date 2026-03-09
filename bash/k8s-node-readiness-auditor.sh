#!/usr/bin/env bash
set -euo pipefail

# k8s-node-readiness-auditor.sh
# Report nodes that are NotReady, unschedulable, or under memory/disk/pid pressure.

usage() {
  cat <<EOF
Usage: $0 [--context CONTEXT] [--output text|json]

Options:
  --context CONTEXT   Kubernetes context to use
  --output FORMAT     Output format: text (default) or json
  -h, --help          Show this help message

Examples:
  bash/k8s-node-readiness-auditor.sh
  bash/k8s-node-readiness-auditor.sh --context prod-cluster --output json
EOF
}

CONTEXT=""
OUTPUT="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "json" ]]; then
  echo "--output must be text or json" >&2
  exit 2
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 3
fi

KUBECTL=(kubectl)
if [[ -n "$CONTEXT" ]]; then
  KUBECTL+=(--context "$CONTEXT")
fi

nodes_json="$(${KUBECTL[@]} get nodes -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c '
  def cond($type): (.status.conditions // [] | map(select(.type == $type)) | first);

  [
    .items[]?
    | .metadata.name as $node
    | cond("Ready") as $ready
    | cond("MemoryPressure") as $mem
    | cond("DiskPressure") as $disk
    | cond("PIDPressure") as $pid
    | {
        node: $node,
        ready_status: ($ready.status // "Unknown"),
        ready_reason: ($ready.reason // "unknown"),
        unschedulable: (.spec.unschedulable // false),
        memory_pressure: (($mem.status // "False") == "True"),
        disk_pressure: (($disk.status // "False") == "True"),
        pid_pressure: (($pid.status // "False") == "True")
      }
    | select(
        .ready_status != "True"
        or .unschedulable == true
        or .memory_pressure == true
        or .disk_pressure == true
        or .pid_pressure == true
      )
  ]
' <<< "$nodes_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
node_count="$(jq '.items | length' <<< "$nodes_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg context "${CONTEXT:-current}" \
    --argjson node_count "$node_count" \
    --argjson findings "$findings_json" \
    '{context:$context, node_count:$node_count, problematic_nodes:$findings}'
else
  echo "K8s Node Readiness Auditor"
  echo "Context: ${CONTEXT:-current}"
  echo "Nodes checked: $node_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "All nodes look healthy (Ready/schedulable/no pressure flags)."
  else
    echo "Problematic nodes: $finding_count"
    jq -r '.[] | "- \(.node) ready=\(.ready_status) unschedulable=\(.unschedulable) memPressure=\(.memory_pressure) diskPressure=\(.disk_pressure) pidPressure=\(.pid_pressure)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 ]]; then
  exit 1
fi

exit 0
