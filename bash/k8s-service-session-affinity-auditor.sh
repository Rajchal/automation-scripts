#!/usr/bin/env bash
set -euo pipefail

# k8s-service-session-affinity-auditor.sh
# Detect Services with sessionAffinity configured.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Reports Services configured with sessionAffinity other than None.
  - Useful for identifying Services that maintain client session affinity in the cluster.

Examples:
  bash/k8s-service-session-affinity-auditor.sh
  bash/k8s-service-session-affinity-auditor.sh --output json
  bash/k8s-service-session-affinity-auditor.sh --output json --no-fail
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
  | {namespace:.metadata.namespace, name:.metadata.name, sessionAffinity:(.spec.sessionAffinity // "None"), affinityConfig:(.spec.sessionAffinityConfig // {})}
  | select(.sessionAffinity != "None")
' <<< "$services_json")"

result="$(jq -n --argjson findings "[$findings]" '{services_with_session_affinity:$findings}')"
count="$(jq '.services_with_session_affinity | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No Services with sessionAffinity were detected."
  else
    echo "Services with sessionAffinity (count=$count):"
    jq -r '.services_with_session_affinity[] | "- \(.namespace)/\(.name) affinity=\(.sessionAffinity)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
