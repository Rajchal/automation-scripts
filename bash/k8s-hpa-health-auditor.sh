#!/usr/bin/env bash
set -euo pipefail

# k8s-hpa-health-auditor.sh
# Report HorizontalPodAutoscalers that are unable to scale or stuck at min/max replicas.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json]

Options:
  --namespace NS      Check only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter HPAs (default: none)
  --output FORMAT     Output format: text (default) or json
  -h, --help          Show this help message

Examples:
  bash/k8s-hpa-health-auditor.sh
  bash/k8s-hpa-health-auditor.sh --namespace production
  bash/k8s-hpa-health-auditor.sh --output json
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

hpa_json="$(${KUBECTL[@]} get hpa "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

issues_json="$(jq -c '
  def cond($type): (.status.conditions // [] | map(select(.type == $type)) | first);

  [
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $name
    | (.spec.minReplicas // 1) as $min
    | (.spec.maxReplicas // 1) as $max
    | (.status.currentReplicas // 0) as $current
    | (.status.desiredReplicas // 0) as $desired
    | cond("AbleToScale") as $able
    | cond("ScalingActive") as $active
    | cond("ScalingLimited") as $limited
    | {
        namespace: $ns,
        hpa: $name,
        min_replicas: $min,
        max_replicas: $max,
        current_replicas: $current,
        desired_replicas: $desired,
        able_to_scale_status: ($able.status // "Unknown"),
        able_to_scale_reason: ($able.reason // "unknown"),
        scaling_active_status: ($active.status // "Unknown"),
        scaling_active_reason: ($active.reason // "unknown"),
        scaling_limited_status: ($limited.status // "Unknown"),
        scaling_limited_reason: ($limited.reason // "unknown"),
        at_min: ($current == $min),
        at_max: ($current == $max)
      }
    | select(
        .able_to_scale_status == "False"
        or .scaling_active_status == "False"
        or .scaling_limited_status == "True"
      )
  ]
' <<< "$hpa_json")"

issue_count="$(jq 'length' <<< "$issues_json")"
hpa_count="$(jq '.items | length' <<< "$hpa_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson hpa_count "$hpa_count" \
    --argjson issues "$issues_json" \
    '{scope:$scope, context:$context, selector:$selector, hpa_count:$hpa_count, hpa_health_issues:$issues}'
else
  echo "K8s HPA Health Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "HPAs checked: $hpa_count"
  echo ""

  if [[ "$issue_count" -eq 0 ]]; then
    echo "No HPA health issues found (AbleToScale/ScalingActive/ScalingLimited checks)."
  else
    echo "HPAs with potential health issues: $issue_count"
    jq -r '.[] | "- \(.namespace)/\(.hpa) current=\(.current_replicas) desired=\(.desired_replicas) min=\(.min_replicas) max=\(.max_replicas) ableToScale=\(.able_to_scale_status) scalingActive=\(.scaling_active_status) scalingLimited=\(.scaling_limited_status)"' <<< "$issues_json"
  fi
fi

if [[ "$issue_count" -gt 0 ]]; then
  exit 1
fi

exit 0
