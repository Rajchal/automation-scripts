#!/usr/bin/env bash
set -euo pipefail

# k8s-service-externalname-auditor.sh
# Detect Services of type ExternalName.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Reports Service objects configured as ExternalName.
  - Useful for identifying Services that delegate hostname resolution outside the cluster.

Examples:
  bash/k8s-service-externalname-auditor.sh
  bash/k8s-service-externalname-auditor.sh --output json
  bash/k8s-service-externalname-auditor.sh --output json --no-fail
EOF
}

OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="${2:-}"; shift 2
      ;;
    --no-fail)
      NO_FAIL=true; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage; exit 2
      ;;
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

services_json="$(kubectl get services --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
findings="$(jq -c '
  .items[]?
  | select(.spec.type == "ExternalName" or (.spec.externalName // empty) != null)
  | {namespace:.metadata.namespace, name:.metadata.name, externalName:.spec.externalName}
' <<< "$services_json")"

result="$(jq -n --argjson findings "[$findings]" '{externalname_services:$findings}')"
count="$(jq '.externalname_services | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No ExternalName Services were detected."
  else
    echo "ExternalName Services (count=$count):"
    jq -r '.externalname_services[] | "- \(.namespace)/\(.name) -> \(.externalName)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
