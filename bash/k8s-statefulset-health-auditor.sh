#!/usr/bin/env bash
set -euo pipefail

# k8s-statefulset-health-auditor.sh
# Report StatefulSets that are not fully ready/current/updated or have observed generation lag.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json]

Options:
  --namespace NS      Check only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter StatefulSets (default: none)
  --output FORMAT     Output format: text (default) or json
  -h, --help          Show this help message

Examples:
  bash/k8s-statefulset-health-auditor.sh
  bash/k8s-statefulset-health-auditor.sh --namespace production
  bash/k8s-statefulset-health-auditor.sh --output json
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

sts_json="$(${KUBECTL[@]} get statefulset "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

issues_json="$(jq -c '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $name
    | (.metadata.generation // 0) as $gen
    | (.status.observedGeneration // 0) as $obs_gen
    | (.spec.replicas // 1) as $desired
    | (.status.replicas // 0) as $replicas
    | (.status.readyReplicas // 0) as $ready
    | (.status.currentReplicas // 0) as $current
    | (.status.updatedReplicas // 0) as $updated
    | {
        namespace: $ns,
        statefulset: $name,
        desired_replicas: $desired,
        replicas: $replicas,
        ready_replicas: $ready,
        current_replicas: $current,
        updated_replicas: $updated,
        generation: $gen,
        observed_generation: $obs_gen,
        observed_generation_lag: ($obs_gen < $gen)
      }
    | select(
        .ready_replicas < .desired_replicas
        or .current_replicas < .desired_replicas
        or .updated_replicas < .desired_replicas
        or .observed_generation_lag == true
      )
  ]
' <<< "$sts_json")"

issue_count="$(jq 'length' <<< "$issues_json")"
sts_count="$(jq '.items | length' <<< "$sts_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson statefulset_count "$sts_count" \
    --argjson issues "$issues_json" \
    '{scope:$scope, context:$context, selector:$selector, statefulset_count:$statefulset_count, unhealthy_statefulsets:$issues}'
else
  echo "K8s StatefulSet Health Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "StatefulSets checked: $sts_count"
  echo ""

  if [[ "$issue_count" -eq 0 ]]; then
    echo "All checked StatefulSets look healthy."
  else
    echo "Potentially unhealthy StatefulSets: $issue_count"
    jq -r '.[] | "- \(.namespace)/\(.statefulset) desired=\(.desired_replicas) ready=\(.ready_replicas) current=\(.current_replicas) updated=\(.updated_replicas) observedLag=\(.observed_generation_lag)"' <<< "$issues_json"
  fi
fi

if [[ "$issue_count" -gt 0 ]]; then
  exit 1
fi

exit 0
