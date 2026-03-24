#!/usr/bin/env bash
set -euo pipefail

# k8s-resource-quota-policy-auditor.sh
# Report containers missing CPU/memory requests or limits.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--kind deployment,statefulset,daemonset,replicaset,pod] [--output text|json] [--no-fail]

Options:
  --namespace NS      Audit one namespace (default all)
  --context CONTEXT   Kubernetes context
  --selector S        Label selector
  --kind LIST         Comma-separated resources to scan (default all)
  --output FORMAT     text or json
  --no-fail           Exit 0 even when findings exist
  -h, --help          Show help

Notes:
  - Flags containers (including initContainers) lacking either resource requests or limits for CPU/memory.

Examples:
  bash/k8s-resource-quota-policy-auditor.sh
  bash/k8s-resource-quota-policy-auditor.sh --namespace production --kind deployment
  bash/k8s-resource-quota-policy-auditor.sh --output json --no-fail
EOF
}

NAMESPACE=""
CONTEXT=""
SELECTOR=""
KINDS="deployment,statefulset,daemonset,replicaset,pod"
OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --selector) SELECTOR="${2:-}"; shift 2 ;;
    --kind) KINDS="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --no-fail) NO_FAIL=true; shift ;;
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
if [[ -n "$CONTEXT" ]]; then KUBECTL+=(--context "$CONTEXT"); fi
ns_args=(); [[ -n "$NAMESPACE" ]] && ns_args=(-n "$NAMESPACE") || ns_args=(--all-namespaces)
selector_args=(); [[ -n "$SELECTOR" ]] && selector_args=(-l "$SELECTOR")

workloads_json="$(${KUBECTL[@]} get ${KINDS} "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .kind as $kind
    | .metadata.name as $workload
    | .spec.template.spec? as $spec
    | ((.spec.containers // []) + (.spec.initContainers // []))[]? as $container
    | .name as $container_name
    | .resources as $resources
    | (if ($resources.requests.cpu // null) == null then true else false end) as $missing_request_cpu
    | (if ($resources.requests.memory // null) == null then true else false end) as $missing_request_memory
    | (if ($resources.limits.cpu // null) == null then true else false end) as $missing_limit_cpu
    | (if ($resources.limits.memory // null) == null then true else false end) as $missing_limit_memory
    | select($missing_request_cpu or $missing_request_memory or $missing_limit_cpu or $missing_limit_memory)
    | {
        namespace: $ns,
        kind: $kind,
        workload: $workload,
        container: $container_name,
        missing_request_cpu: $missing_request_cpu,
        missing_request_memory: $missing_request_memory,
        missing_limit_cpu: $missing_limit_cpu,
        missing_limit_memory: $missing_limit_memory,
        issue: "MissingResourceRequestsOrLimits"
      }
  ]
' <<< "$workloads_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
workload_count="$(jq '.items | length' <<< "$workloads_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n --arg scope "${NAMESPACE:-all}" --arg context "${CONTEXT:-current}" --arg selector "${SELECTOR:-none}" --arg kinds "$KINDS" --argjson workload_count "$workload_count" --argjson findings "$findings_json" '{scope:$scope, context:$context, selector:$selector, kinds:$kinds, workload_count:$workload_count, findings:$findings}'
else
  echo "K8s Resource Requests/Limits Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Kinds: $KINDS"
  echo "Workloads scanned: $workload_count"
  echo ""
  if [[ "$finding_count" -eq 0 ]]; then
    echo "All containers have both CPU/memory resource requests and limits."
  else
    echo "Containers missing resource requests/limits: $finding_count"
    jq -r '.[] | "- [\(.kind)] \(.namespace)/\(.workload) container=\(.container) miss_request_cpu=\(.missing_request_cpu) miss_request_memory=\(.missing_request_memory) miss_limit_cpu=\(.missing_limit_cpu) miss_limit_memory=\(.missing_limit_memory)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then exit 1; fi
exit 0
