#!/usr/bin/env bash
set -euo pipefail

# k8s-service-port-name-auditor.sh
# Detect Services with ports that do not define a name.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Reports Services where one or more ports are missing the required name field.
  - Useful for identifying Services that may be incompatible with EndpointSlice, ingress, or headless service expectations.

Examples:
  bash/k8s-service-port-name-auditor.sh
  bash/k8s-service-port-name-auditor.sh --output json
  bash/k8s-service-port-name-auditor.sh --output json --no-fail
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
  | {namespace:.metadata.namespace, name:.metadata.name, unnamedPorts:(.spec.ports // [] | map(select(.name == null or .name == "")) | map({port:.port, protocol:.protocol, targetPort:(.targetPort // "")}))}
  | select(.unnamedPorts | length > 0)
' <<< "$services_json")"

result="$(jq -n --argjson findings "[$findings]" '{services_with_unnamed_ports:$findings}')"
count="$(jq '.services_with_unnamed_ports | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No Services with unnamed ports were detected."
  else
    echo "Services with unnamed ports (count=$count):"
    jq -r '.services_with_unnamed_ports[] | "- \(.namespace)/\(.name) ports=\(.unnamedPorts | map("port="+(.port|tostring)+",proto="+(.protocol//"" )+",targetPort="+(.targetPort|tostring)) | join("; "))"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
