#!/usr/bin/env bash
set -euo pipefail

# k8s-deployment-health-auditor.sh
# Report Deployments that are unavailable, not progressing, or not meeting desired replica count.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json]

Options:
  --namespace NS      Check only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter Deployments (default: none)
  --output FORMAT     Output format: text (default) or json
  -h, --help          Show this help message

Examples:
  bash/k8s-deployment-health-auditor.sh
  bash/k8s-deployment-health-auditor.sh --namespace production
  bash/k8s-deployment-health-auditor.sh --output json
EOF
}

NAMESPACE=""
CONTEXT=""
SELECTOR=""
OUTPUT="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --selector) SELECTOR="${2:-}"; shift 2 ;;
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

deploy_json="$(${KUBECTL[@]} get deploy "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

issues_json="$(jq -c '
  def cond($type): (.status.conditions // [] | map(select(.type == $type)) | first);

  [
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $name
    | (.spec.replicas // 1) as $desired
    | (.status.availableReplicas // 0) as $available
    | (.status.updatedReplicas // 0) as $updated
    | (.status.readyReplicas // 0) as $ready
    | cond("Available") as $available_cond
    | cond("Progressing") as $progressing_cond
    | {
        namespace: $ns,
        deployment: $name,
        desired_replicas: $desired,
        ready_replicas: $ready,
        available_replicas: $available,
        updated_replicas: $updated,
        progressing_status: ($progressing_cond.status // "Unknown"),
        progressing_reason: ($progressing_cond.reason // "unknown"),
        available_status: ($available_cond.status // "Unknown"),
        available_reason: ($available_cond.reason // "unknown")
      }
    | select(
        .available_replicas < .desired_replicas
        or .ready_replicas < .desired_replicas
        or .updated_replicas < .desired_replicas
        or .progressing_status == "False"
        or .available_status == "False"
      )
  ]
' <<< "$deploy_json")"

issue_count="$(jq 'length' <<< "$issues_json")"
deploy_count="$(jq '.items | length' <<< "$deploy_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson deployment_count "$deploy_count" \
    --argjson issues "$issues_json" \
    '{scope:$scope, context:$context, selector:$selector, deployment_count:$deployment_count, unhealthy_deployments:$issues}'
else
  echo "K8s Deployment Health Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Deployments checked: $deploy_count"
  echo ""

  if [[ "$issue_count" -eq 0 ]]; then
    echo "All checked deployments look healthy."
  else
    echo "Potentially unhealthy deployments: $issue_count"
    jq -r '.[] | "- \(.namespace)/\(.deployment) desired=\(.desired_replicas) ready=\(.ready_replicas) available=\(.available_replicas) updated=\(.updated_replicas) progressing=\(.progressing_status) availableCond=\(.available_status)"' <<< "$issues_json"
  fi
fi

if [[ "$issue_count" -gt 0 ]]; then
  exit 1
fi

exit 0
