#!/usr/bin/env bash
set -euo pipefail

# k8s-priorityclass-coverage-auditor.sh
# Report active pods that do not set priorityClassName explicitly.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--output text|json] [--no-fail]

Options:
  --namespace NS      Audit only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Examples:
  bash/k8s-priorityclass-coverage-auditor.sh
  bash/k8s-priorityclass-coverage-auditor.sh --namespace production
  bash/k8s-priorityclass-coverage-auditor.sh --output json --no-fail
EOF
}

NAMESPACE=""
CONTEXT=""
OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --no-fail) NO_FAIL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
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

ns_args=()
if [[ -n "$NAMESPACE" ]]; then
  ns_args=(-n "$NAMESPACE")
else
  ns_args=(--all-namespaces)
fi

pods_json="$(${KUBECTL[@]} get pods "${ns_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c '
  [
    .items[]?
    | select((.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed")
    | select((.spec.priorityClassName // "") == "")
    | {
        namespace: .metadata.namespace,
        pod: .metadata.name,
        node: (.spec.nodeName // "<unassigned>"),
        qos_class: (.status.qosClass // "Unknown")
      }
  ]
' <<< "$pods_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
active_pod_count="$(jq '[.items[]? | select((.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed")] | length' <<< "$pods_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --argjson active_pod_count "$active_pod_count" \
    --argjson pods_missing_priority_class "$findings_json" \
    '{scope:$scope, context:$context, active_pod_count:$active_pod_count, pods_missing_priority_class:$pods_missing_priority_class}'
else
  echo "K8s PriorityClass Coverage Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Active pods scanned: $active_pod_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "All active pods have an explicit priorityClassName."
  else
    echo "Pods without explicit priorityClassName: $finding_count"
    jq -r '.[] | "- \(.namespace)/\(.pod) node=\(.node) qos=\(.qos_class)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
