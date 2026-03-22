#!/usr/bin/env bash
set -euo pipefail

# k8s-pod-affinity-auditor.sh
# Report workloads that do not define any podAffinity/podAntiAffinity in pod template.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json] [--no-fail]

Options:
  --namespace NS      Audit only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter workloads (default: none)
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Flags deployments/statefulsets/daemonsets without podAffinity or podAntiAffinity in pod template.

Examples:
  bash/k8s-pod-affinity-auditor.sh
  bash/k8s-pod-affinity-auditor.sh --namespace production
  bash/k8s-pod-affinity-auditor.sh --output json --no-fail
EOF
}

NAMESPACE=""
CONTEXT=""
SELECTOR=""
OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --selector) SELECTOR="${2:-}"; shift 2 ;;
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

selector_args=()
if [[ -n "$SELECTOR" ]]; then
  selector_args=(-l "$SELECTOR")
fi

resources="deployment,statefulset,daemonset"
workloads_json="$(${KUBECTL[@]} get $resources "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .kind as $kind
    | .metadata.name as $name
    | .spec.template.spec.affinity as $affinity
    | select($affinity == null or ($affinity.podAffinity == null and $affinity.podAntiAffinity == null))
    | {
        namespace: $ns,
        kind: $kind,
        workload: $name,
        issue: "MissingPodAffinityRules"
      }
  ]
' <<< "$workloads_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
workload_count="$(jq '.items | length' <<< "$workloads_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson workload_count "$workload_count" \
    --argjson findings "$findings_json" \
    '{scope:$scope, context:$context, selector:$selector, workload_count:$workload_count, pod_affinity_findings:$findings}'
else
  echo "K8s Pod Affinity Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Workloads scanned: $workload_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "All checked workloads define podAffinity or podAntiAffinity."
  else
    echo "Workloads missing podAffinity/podAntiAffinity: $finding_count"
    jq -r '.[] | "- [\(.kind)] \(.namespace)/\(.workload)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0