#!/usr/bin/env bash
set -euo pipefail

# k8s-pod-state-auditor.sh
# Report pods with CrashLoopBackOff / ImagePullBackOff / ErrImagePull states or high restart counts.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--restart-threshold N] [--output text|json]

Options:
  --namespace NS          Check only one namespace (default: all namespaces)
  --context CONTEXT       Kubernetes context to use
  --selector S            Label selector to filter pods (default: none)
  --restart-threshold N   Flag containers with restartCount >= N (default: 5)
  --output FORMAT         Output format: text (default) or json
  -h, --help              Show this help message

Examples:
  bash/k8s-pod-state-auditor.sh
  bash/k8s-pod-state-auditor.sh --namespace production --restart-threshold 3
  bash/k8s-pod-state-auditor.sh --output json
EOF
}

NAMESPACE=""
CONTEXT=""
SELECTOR=""
RESTART_THRESHOLD=5
OUTPUT="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --selector) SELECTOR="${2:-}"; shift 2 ;;
    --restart-threshold) RESTART_THRESHOLD="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if ! [[ "$RESTART_THRESHOLD" =~ ^[0-9]+$ ]]; then
  echo "--restart-threshold must be a non-negative integer" >&2
  exit 2
fi

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

pods_json="$(${KUBECTL[@]} get pods "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c --argjson threshold "$RESTART_THRESHOLD" '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $pod
    | (
        [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]]
        | map(select(type == "object"))
      ) as $statuses
    | (
        [
          $statuses[]
          | select((.state.waiting.reason // "") | IN("CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull"))
          | {
              namespace: $ns,
              pod: $pod,
              container: (.name // "unknown"),
              issue: (.state.waiting.reason // "waiting"),
              restart_count: (.restartCount // 0)
            }
        ]
      +
        [
          $statuses[]
          | select((.restartCount // 0) >= $threshold)
          | {
              namespace: $ns,
              pod: $pod,
              container: (.name // "unknown"),
              issue: "HighRestartCount",
              restart_count: (.restartCount // 0)
            }
        ]
      )[]
  ]
  | unique_by(.namespace, .pod, .container, .issue)
' <<< "$pods_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
pod_count="$(jq '.items | length' <<< "$pods_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson restart_threshold "$RESTART_THRESHOLD" \
    --argjson pod_count "$pod_count" \
    --argjson findings "$findings_json" \
    '{scope:$scope, context:$context, selector:$selector, restart_threshold:$restart_threshold, pod_count:$pod_count, findings:$findings}'
else
  echo "K8s Pod State Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Restart threshold: $RESTART_THRESHOLD"
  echo "Pods checked: $pod_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "No CrashLoop/ImagePull/high-restart issues detected."
  else
    echo "Findings: $finding_count"
    jq -r '.[] | "- \(.namespace)/\(.pod) container=\(.container) issue=\(.issue) restarts=\(.restart_count)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 ]]; then
  exit 1
fi

exit 0
