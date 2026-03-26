#!/usr/bin/env bash
set -euo pipefail

# k8s-service-without-selector-auditor.sh
# Detect Services that do not define selectors (except ExternalName) and likely have no backend pods.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Targets Services where spec.selector is empty/null and spec.type != ExternalName.
  - Protected for services auto-managed by externalName, headless, etc.

Examples:
  bash/k8s-service-without-selector-auditor.sh
  bash/k8s-service-without-selector-auditor.sh --output json
  bash/k8s-service-without-selector-auditor.sh --output json --no-fail
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

svcs_json="$(kubectl get svc --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
findings="$(jq -c '.items[]? | select(.spec.type != "ExternalName") | select(.spec.selector == null or (.spec.selector | length == 0)) | {namespace:.metadata.namespace, name:.metadata.name, type:.spec.type, clusterIP:.spec.clusterIP, ports:.spec.ports}' <<< "$svcs_json")"
result="$(jq -n --argjson findings "[$findings]" '{services_without_selector:$findings}')"
count="$(jq '.services_without_selector | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No non-ExternalName services without selectors found."
  else
    echo "Services without selectors (non-ExternalName, count=$count):"
    jq -r '.services_without_selector[] | "- \(.namespace)/\(.name) type=\(.type) clusterIP=\(.clusterIP) ports=\(.ports | map(.port) | join(","))"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
