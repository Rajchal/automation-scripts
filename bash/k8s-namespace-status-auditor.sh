#!/usr/bin/env bash
set -euo pipefail

# k8s-namespace-status-auditor.sh
# Report namespaces that are not in Active status.

usage() {
  cat <<EOF
Usage: $0 [--context CONTEXT] [--output text|json] [--no-fail]

Options:
  --context CONTEXT   Kubernetes context to use
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Flags namespaces whose .status.phase is not Active.

Examples:
  bash/k8s-namespace-status-auditor.sh
  bash/k8s-namespace-status-auditor.sh --context kube-prod
  bash/k8s-namespace-status-auditor.sh --output json --no-fail
EOF
}

CONTEXT=""
OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
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

namespaces_json="$(${KUBECTL[@]} get namespaces -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c '
  [
    .items[]?
    | select(.status.phase != "Active")
    | {
        namespace: .metadata.name,
        status: .status.phase,
        issue: "NamespaceNotActive"
      }
  ]
' <<< "$namespaces_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
namespace_count="$(jq '.items | length' <<< "$namespaces_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg context "${CONTEXT:-current}" \
    --argjson namespace_count "$namespace_count" \
    --argjson findings "$findings_json" \
    '{context:$context, namespace_count:$namespace_count, namespaces_not_active:$findings}'
else
  echo "K8s Namespace Status Auditor"
  echo "Context: ${CONTEXT:-current}"
  echo "Namespaces scanned: $namespace_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "All namespaces are Active."
  else
    echo "Namespaces not Active: $finding_count"
    jq -r '.[] | "- \(.namespace) status=\(.status)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
