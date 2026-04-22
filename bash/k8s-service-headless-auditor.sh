#!/usr/bin/env bash
set -euo pipefail

# k8s-service-headless-auditor.sh
# Detect Services configured as headless (clusterIP=None).

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Reports Services with spec.clusterIP set to None.
  - Useful for identifying headless Services that route directly to pods without cluster IP load balancing.

Examples:
  bash/k8s-service-headless-auditor.sh
  bash/k8s-service-headless-auditor.sh --output json
  bash/k8s-service-headless-auditor.sh --output json --no-fail
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
  | select((.spec.clusterIP // "") == "None")
  | {namespace:.metadata.namespace, name:.metadata.name, type:(.spec.type // "ClusterIP"), clusterIP:.spec.clusterIP}
' <<< "$services_json")"

result="$(jq -n --argjson findings "[$findings]" '{headless_services:$findings}')"
count="$(jq '.headless_services | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No headless Services were detected."
  else
    echo "Headless Services (count=$count):"
    jq -r '.headless_services[] | "- \(.namespace)/\(.name) type=\(.type) clusterIP=\(.clusterIP)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
