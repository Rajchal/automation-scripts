#!/usr/bin/env bash
set -euo pipefail

# k8s-unused-serviceaccount-auditor.sh
# Detect ServiceAccounts that are not referenced by any running pod in the cluster.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans all namespaces for ServiceAccounts and running pods.
  - Reports ServiceAccounts that have no pods using them currently.

Examples:
  bash/k8s-unused-serviceaccount-auditor.sh
  bash/k8s-unused-serviceaccount-auditor.sh --output json
  bash/k8s-unused-serviceaccount-auditor.sh --output json --no-fail
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

sa_json="$(kubectl get serviceaccount --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
pod_json="$(kubectl get pods --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"

used_sas="$(jq -r '.items[]? | .spec.serviceAccountName // "default" as $sa | "\(.metadata.namespace)/\($sa)"' <<< "$pod_json" | sort -u)"

findings="$(jq -c --argjson used "[$(printf '%s
' "$used_sas" | jq -R . | paste -sd, -))" '
  .items[]? | {namespace:.metadata.namespace, name:.metadata.name} | .key = "\(.namespace)/\(.name)" | select(.key as $key | $used | index($key) | not) | {namespace:.namespace, name:.name}
' <<< "$sa_json")"

# If there are no pods at all, then all SAs appear unused but this is acceptable to report as findings.

result="$(jq -n --argjson findings "[$findings]" '{unused_serviceaccounts:$findings}')"
count="$(jq '.unused_serviceaccounts | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No unused ServiceAccounts detected."
  else
    echo "Unused ServiceAccounts (count=$count):"
    jq -r '.unused_serviceaccounts[] | "- \(.namespace)/\(.name)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
