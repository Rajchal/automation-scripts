#!/usr/bin/env bash
set -euo pipefail

# k8s-networkpolicy-coverage-auditor.sh
# Report namespaces that have pods but no NetworkPolicy objects.

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
  bash/k8s-networkpolicy-coverage-auditor.sh
  bash/k8s-networkpolicy-coverage-auditor.sh --namespace production
  bash/k8s-networkpolicy-coverage-auditor.sh --output json --no-fail
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
netpol_json="$(${KUBECTL[@]} get networkpolicy "${ns_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

ns_findings_json="$(jq -c --argjson nps "$netpol_json" '
  def np_count($ns): ([ $nps.items[]? | select(.metadata.namespace == $ns) ] | length);

  [
    .items[]?
    | select((.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed")
    | .metadata.namespace
  ]
  | group_by(.)
  | map({
      namespace: .[0],
      active_pod_count: length,
      networkpolicy_count: np_count(.[0])
    })
  | map(select(.networkpolicy_count == 0))
' <<< "$pods_json")"

finding_count="$(jq 'length' <<< "$ns_findings_json")"
active_pod_count="$(jq '[.items[]? | select((.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed")] | length' <<< "$pods_json")"
np_count="$(jq '.items | length' <<< "$netpol_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --argjson active_pod_count "$active_pod_count" \
    --argjson networkpolicy_count "$np_count" \
    --argjson namespaces_without_networkpolicy "$ns_findings_json" \
    '{scope:$scope, context:$context, active_pod_count:$active_pod_count, networkpolicy_count:$networkpolicy_count, namespaces_without_networkpolicy:$namespaces_without_networkpolicy}'
else
  echo "K8s NetworkPolicy Coverage Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Active pods scanned: $active_pod_count"
  echo "NetworkPolicies scanned: $np_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "All namespaces with active pods have at least one NetworkPolicy."
  else
    echo "Namespaces with active pods but no NetworkPolicy: $finding_count"
    jq -r '.[] | "- \(.namespace) activePods=\(.active_pod_count) networkPolicies=\(.networkpolicy_count)"' <<< "$ns_findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
