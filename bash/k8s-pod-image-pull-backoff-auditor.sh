#!/usr/bin/env bash
set -euo pipefail

# k8s-pod-image-pull-backoff-auditor.sh
# Report pods with containers in ImagePullBackOff or ErrImagePull state.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json] [--no-fail]

Options:
  --namespace NS      Audit only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter pods (default: none)
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Flags pods with container statuses indicating ImagePullBackOff or ErrImagePull.
  - Useful for identifying image resolution failures in workloads.

Examples:
  bash/k8s-pod-image-pull-backoff-auditor.sh
  bash/k8s-pod-image-pull-backoff-auditor.sh --namespace production
  bash/k8s-pod-image-pull-backoff-auditor.sh --output json --no-fail
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

for cmd in kubectl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required" >&2
    exit 3
  fi
done

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

findings_json="$(jq -c '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $pod
    | (.status.containerStatuses // [] + .status.initContainerStatuses // [])[]?
    | select(.state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull")
    | {
        namespace: $ns,
        pod: $pod,
        container_name: (.name // "unknown"),
        state: .state.waiting.reason,
        message: (.state.waiting.message // ""),
        issue: "ImagePullFailure"
      }
  ]
' <<< "$pods_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
pod_count="$(jq '.items | length' <<< "$pods_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson pod_count "$pod_count" \
    --argjson findings "$findings_json" \
    '{scope:$scope, context:$context, selector:$selector, pod_count:$pod_count, image_pull_backoff_findings:$findings}'
else
  echo "K8s Pod ImagePullBackOff Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Pods checked: $pod_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "No pods with ImagePullBackOff or ErrImagePull were found."
  else
    echo "Pods with image pull failures: $finding_count"
    jq -r '.[] | "- \(.namespace)/\(.pod) container=\(.container_name) state=\(.state) message=\(.message)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
