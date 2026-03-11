#!/usr/bin/env bash
set -euo pipefail

# k8s-image-pull-policy-auditor.sh
# Flag containers using :latest without imagePullPolicy=Always.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json] [--no-fail]

Options:
  --namespace NS      Audit only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector for workloads (default: none)
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Examples:
  bash/k8s-image-pull-policy-auditor.sh
  bash/k8s-image-pull-policy-auditor.sh --namespace production
  bash/k8s-image-pull-policy-auditor.sh --output json --no-fail
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

workloads_json="$(${KUBECTL[@]} get deploy,statefulset,daemonset "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .kind as $kind
    | .metadata.name as $name
    | [(.spec.template.spec.containers // [])[], (.spec.template.spec.initContainers // [])[]]
    | map(select(type == "object"))[]
    | . as $c
    | ($c.image // "") as $image
    | ($c.imagePullPolicy // "IfNotPresent") as $policy
    | select($image | test("(^|.*/)[^:@]+:latest$"))
    | select($policy != "Always")
    | {
        namespace: $ns,
        kind: $kind,
        workload: $name,
        container: ($c.name // "unknown"),
        image: $image,
        image_pull_policy: $policy,
        issue: "LatestTagWithoutAlwaysPull"
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
    '{scope:$scope, context:$context, selector:$selector, workload_count:$workload_count, image_pull_policy_findings:$findings}'
else
  echo "K8s Image Pull Policy Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Workloads checked: $workload_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "No :latest image pull policy issues found."
  else
    echo "Findings: $finding_count"
    jq -r '.[] | "- \(.namespace)/\(.kind)/\(.workload) container=\(.container) image=\(.image) imagePullPolicy=\(.image_pull_policy)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
