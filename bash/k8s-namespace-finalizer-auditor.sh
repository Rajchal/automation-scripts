#!/usr/bin/env bash
set -euo pipefail

# k8s-namespace-finalizer-auditor.sh
# Report namespaces that have finalizers configured.

usage() {
  cat <<EOF
Usage: $0 [--context CONTEXT] [--output text|json] [--no-fail]

Options:
  --context CONTEXT   Kubernetes context to use
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Flags namespaces whose metadata.finalizers list is non-empty.
  - Useful for identifying namespaces that may be blocked from deletion.

Examples:
  bash/k8s-namespace-finalizer-auditor.sh
  bash/k8s-namespace-finalizer-auditor.sh --context kube-prod
  bash/k8s-namespace-finalizer-auditor.sh --output json --no-fail
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

namespaces_json="$(${KUBECTL[@]} get namespaces -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c '
  [
    .items[]?
    | select((.metadata.finalizers // []) | length > 0)
    | {
        namespace: .metadata.name,
        finalizers: .metadata.finalizers,
        issue: "NamespaceHasFinalizers"
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
    '{context:$context, namespace_count:$namespace_count, namespaces_with_finalizers:$findings}'
else
  echo "K8s Namespace Finalizer Auditor"
  echo "Context: ${CONTEXT:-current}"
  echo "Namespaces scanned: $namespace_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "No namespaces with metadata.finalizers were found."
  else
    echo "Namespaces with finalizers: $finding_count"
    jq -r '.[] | "- \(.namespace) finalizers=\(.finalizers | join(","))"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
