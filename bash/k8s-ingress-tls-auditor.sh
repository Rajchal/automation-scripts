#!/usr/bin/env bash
set -euo pipefail

# k8s-ingress-tls-auditor.sh
# Detect Ingress resources missing TLS configuration.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans all Ingress objects and reports those without TLS blocks.
  - Useful to identify Ingresses accepting traffic without HTTPS termination.

Examples:
  bash/k8s-ingress-tls-auditor.sh
  bash/k8s-ingress-tls-auditor.sh --output json
  bash/k8s-ingress-tls-auditor.sh --output json --no-fail
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

ingresses_json="$(kubectl get ingress --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
findings="$(jq -c '
  .items[]?
  | {namespace:.metadata.namespace, name:.metadata.name, tls:(.spec.tls // [])}
  | select(.tls | length == 0)
' <<< "$ingresses_json")"

result="$(jq -n --argjson findings "[$findings]" '{ingresses_missing_tls:$findings}')"
count="$(jq '.ingresses_missing_tls | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No Ingress resources missing TLS configuration."
  else
    echo "Ingress resources missing TLS configuration (count=$count):"
    jq -r '.ingresses_missing_tls[] | "- \(.namespace)/\(.name)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
