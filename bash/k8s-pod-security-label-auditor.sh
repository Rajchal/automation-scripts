#!/usr/bin/env bash
set -euo pipefail

# k8s-pod-security-label-auditor.sh
# Report namespaces missing recommended Pod Security Admission labels.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--output text|json] [--no-fail]

Options:
  --namespace NS      Audit only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Checks these namespace labels:
    pod-security.kubernetes.io/enforce
    pod-security.kubernetes.io/audit
    pod-security.kubernetes.io/warn

Examples:
  bash/k8s-pod-security-label-auditor.sh
  bash/k8s-pod-security-label-auditor.sh --namespace production
  bash/k8s-pod-security-label-auditor.sh --output json --no-fail
EOF
}

NAMESPACE=""
CONTEXT=""
OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
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
  ns_args=("$NAMESPACE")
fi

namespaces_json=""
if [[ -n "$NAMESPACE" ]]; then
  namespaces_json="$(${KUBECTL[@]} get namespace "$NAMESPACE" -o json 2>/dev/null || echo '{}')"
  namespaces_json="$(jq -c '{items:[.]}' <<< "$namespaces_json")"
else
  namespaces_json="$(${KUBECTL[@]} get namespaces -o json 2>/dev/null || echo '{"items":[]}')"
fi

findings_json="$(jq -c '
  [
    .items[]?
    | .metadata.name as $ns
    | (.metadata.labels // {}) as $labels
    | {
        namespace: $ns,
        enforce: ($labels["pod-security.kubernetes.io/enforce"] // null),
        audit: ($labels["pod-security.kubernetes.io/audit"] // null),
        warn: ($labels["pod-security.kubernetes.io/warn"] // null),
        missing_labels: (
          [
            (if ($labels["pod-security.kubernetes.io/enforce"] // "") == "" then "pod-security.kubernetes.io/enforce" else empty end),
            (if ($labels["pod-security.kubernetes.io/audit"] // "") == "" then "pod-security.kubernetes.io/audit" else empty end),
            (if ($labels["pod-security.kubernetes.io/warn"] // "") == "" then "pod-security.kubernetes.io/warn" else empty end)
          ]
        )
      }
    | select((.missing_labels | length) > 0)
  ]
' <<< "$namespaces_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
ns_count="$(jq '.items | length' <<< "$namespaces_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --argjson namespace_count "$ns_count" \
    --argjson findings "$findings_json" \
    '{scope:$scope, context:$context, namespace_count:$namespace_count, namespaces_missing_psa_labels:$findings}'
else
  echo "K8s Pod Security Label Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Namespaces checked: $ns_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "All checked namespaces have enforce/audit/warn Pod Security labels."
  else
    echo "Namespaces missing Pod Security labels: $finding_count"
    jq -r '.[] | "- \(.namespace) missing=\(.missing_labels | join(","))"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
