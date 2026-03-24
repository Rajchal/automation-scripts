#!/usr/bin/env bash
set -euo pipefail

# k8s-termination-grace-period-auditor.sh
# Report pods with missing or excessively long terminationGracePeriodSeconds.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--threshold SECONDS] [--output text|json] [--no-fail]

Options:
  --namespace NS      Audit only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter pods (default: none)
  --threshold SECONDS Threshold in seconds (default 60).
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Flags pods with no terminationGracePeriodSeconds set or with value above threshold.

Examples:
  bash/k8s-termination-grace-period-auditor.sh
  bash/k8s-termination-grace-period-auditor.sh --namespace production --threshold 30
  bash/k8s-termination-grace-period-auditor.sh --output json --no-fail
EOF
}

NAMESPACE=""
CONTEXT=""
SELECTOR=""
OUTPUT="text"
NO_FAIL=false
THRESHOLD=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --selector) SELECTOR="${2:-}"; shift 2 ;;
    --threshold) THRESHOLD="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --no-fail) NO_FAIL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
  echo "--threshold must be an integer" >&2
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
if [[ -n "$CONTEXT" ]]; then KUBECTL+=(--context "$CONTEXT"); fi
ns_args=(); [[ -n "$NAMESPACE" ]] && ns_args=(-n "$NAMESPACE") || ns_args=(--all-namespaces)
selector_args=(); [[ -n "$SELECTOR" ]] && selector_args=(-l "$SELECTOR")

pods_json="$(${KUBECTL[@]} get pods "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c --argjson thresh "$THRESHOLD" '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $pod
    | .spec.terminationGracePeriodSeconds as $grace
    | select($grace == null or $grace > $thresh)
    | {
        namespace: $ns,
        pod: $pod,
        terminationGracePeriodSeconds: ($grace // "unset"),
        threshold: $thresh,
        issue: "TerminationGracePeriodWarning"
      }
  ]
' <<< "$pods_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
pod_count="$(jq '.items | length' <<< "$pods_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n --arg scope "${NAMESPACE:-all}" --arg context "${CONTEXT:-current}" --arg selector "${SELECTOR:-none}" --argjson pod_count "$pod_count" --argjson threshold "$THRESHOLD" --argjson findings "$findings_json" '{scope:$scope, context:$context, selector:$selector, pod_count:$pod_count, threshold:$threshold, findings:$findings}'
else
  echo "K8s Termination Grace Period Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Pods scanned: $pod_count"
  echo "Threshold: $THRESHOLD"
  echo ""
  if [[ "$finding_count" -eq 0 ]]; then
    echo "All pods have terminationGracePeriodSeconds set within threshold."
  else
    echo "Pods with missing/slow grace period: $finding_count"
    jq -r '.[] | "- \(.namespace)/\(.pod) terminationGracePeriodSeconds=\(.terminationGracePeriodSeconds)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then exit 1; fi
exit 0
