#!/usr/bin/env bash
set -euo pipefail

# k8s-daemonset-rollout-auditor.sh
# Report DaemonSets that are not fully rolled out or have unavailable/misscheduled pods.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json]

Options:
  --namespace NS      Check only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter DaemonSets (default: none)
  --output FORMAT     Output format: text (default) or json
  -h, --help          Show this help message

Examples:
  bash/k8s-daemonset-rollout-auditor.sh
  bash/k8s-daemonset-rollout-auditor.sh --namespace kube-system
  bash/k8s-daemonset-rollout-auditor.sh --output json
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

ds_json="$(${KUBECTL[@]} get daemonset "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

issues_json="$(jq -c '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $name
    | (.status.desiredNumberScheduled // 0) as $desired
    | (.status.currentNumberScheduled // 0) as $current
    | (.status.numberReady // 0) as $ready
    | (.status.updatedNumberScheduled // 0) as $updated
    | (.status.numberAvailable // 0) as $available
    | (.status.numberMisscheduled // 0) as $misscheduled
    | {
        namespace: $ns,
        daemonset: $name,
        desired_scheduled: $desired,
        current_scheduled: $current,
        ready: $ready,
        updated_scheduled: $updated,
        available: $available,
        misscheduled: $misscheduled
      }
    | select(
        .current_scheduled < .desired_scheduled
        or .ready < .desired_scheduled
        or .updated_scheduled < .desired_scheduled
        or .available < .desired_scheduled
        or .misscheduled > 0
      )
  ]
' <<< "$ds_json")"

issue_count="$(jq 'length' <<< "$issues_json")"
ds_count="$(jq '.items | length' <<< "$ds_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson daemonset_count "$ds_count" \
    --argjson issues "$issues_json" \
    '{scope:$scope, context:$context, selector:$selector, daemonset_count:$daemonset_count, unhealthy_daemonsets:$issues}'
else
  echo "K8s DaemonSet Rollout Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "DaemonSets checked: $ds_count"
  echo ""

  if [[ "$issue_count" -eq 0 ]]; then
    echo "All checked DaemonSets appear fully rolled out and healthy."
  else
    echo "Potentially unhealthy DaemonSets: $issue_count"
    jq -r '.[] | "- \(.namespace)/\(.daemonset) desired=\(.desired_scheduled) current=\(.current_scheduled) ready=\(.ready) updated=\(.updated_scheduled) available=\(.available) misscheduled=\(.misscheduled)"' <<< "$issues_json"
  fi
fi

if [[ "$issue_count" -gt 0 ]]; then
  exit 1
fi

exit 0
