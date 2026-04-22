#!/usr/bin/env bash
set -euo pipefail

# k8s-service-loadbalancer-auditor.sh
# Detect LoadBalancer Services without an assigned external ingress.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Reports Services of type LoadBalancer that do not have any status.loadBalancer.ingress entries.
  - Useful for finding load balancer Services still waiting for cloud provider provisioning.

Examples:
  bash/k8s-service-loadbalancer-auditor.sh
  bash/k8s-service-loadbalancer-auditor.sh --output json
  bash/k8s-service-loadbalancer-auditor.sh --output json --no-fail
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
  | select(.spec.type == "LoadBalancer")
  | {namespace:.metadata.namespace, name:.metadata.name, type:.spec.type, ingress:(.status.loadBalancer.ingress // [])}
  | select(.ingress | length == 0)
' <<< "$services_json")"

result="$(jq -n --argjson findings "[$findings]" '{loadbalancer_services_without_ingress:$findings}')"
count="$(jq '.loadbalancer_services_without_ingress | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No LoadBalancer Services without ingress were detected."
  else
    echo "LoadBalancer Services without ingress (count=$count):"
    jq -r '.loadbalancer_services_without_ingress[] | "- \(.namespace)/\(.name)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
