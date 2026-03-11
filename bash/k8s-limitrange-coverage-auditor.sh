#!/usr/bin/env bash
set -euo pipefail

# k8s-limitrange-coverage-auditor.sh
# Report namespaces that have active pods but no LimitRange object.

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
  bash/k8s-limitrange-coverage-auditor.sh
  bash/k8s-limitrange-coverage-auditor.sh --namespace production
  bash/k8s-limitrange-coverage-auditor.sh --output json --no-fail
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
limits_json="$(${KUBECTL[@]} get limitrange "${ns_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c --argjson limits "$limits_json" '
  def limit_count($ns): ([ $limits.items[]? | select(.metadata.namespace == $ns) ] | length);

  [
    .items[]?
    | select((.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed")
    | .metadata.namespace
  ]
  | group_by(.)
  | map({
      namespace: .[0],
      active_pod_count: length,
      limitrange_count: limit_count(.[0])
    })
  | map(select(.limitrange_count == 0))
' <<< "$pods_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
active_pod_count="$(jq '[.items[]? | select((.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed")] | length' <<< "$pods_json")"
limitrange_count="$(jq '.items | length' <<< "$limits_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --argjson active_pod_count "$active_pod_count" \
    --argjson limitrange_count "$limitrange_count" \
    --argjson namespaces_without_limitrange "$findings_json" \
    '{scope:$scope, context:$context, active_pod_count:$active_pod_count, limitrange_count:$limitrange_count, namespaces_without_limitrange:$namespaces_without_limitrange}'
else
  echo "K8s LimitRange Coverage Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Active pods scanned: $active_pod_count"
  echo "LimitRanges scanned: $limitrange_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "All namespaces with active pods have at least one LimitRange."
  else
    echo "Namespaces with active pods but no LimitRange: $finding_count"
    jq -r '.[] | "- \(.namespace) activePods=\(.active_pod_count) limitRanges=\(.limitrange_count)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
