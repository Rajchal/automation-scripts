#!/usr/bin/env bash
set -euo pipefail

# k8s-pvc-storageclass-auditor.sh
# Detect PersistentVolumeClaims without a storageClassName.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans all PVCs and reports those that omit storageClassName.
  - Useful to catch storage provisioning policy gaps and default class reliance.

Examples:
  bash/k8s-pvc-storageclass-auditor.sh
  bash/k8s-pvc-storageclass-auditor.sh --output json
  bash/k8s-pvc-storageclass-auditor.sh --output json --no-fail
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

pvcs_json="$(kubectl get pvc --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
findings="$(jq -c '.items[]? | select(.spec.storageClassName == null) | {namespace:.metadata.namespace, name:.metadata.name, status:.status.phase}' <<< "$pvcs_json")"

result="$(jq -n --argjson findings "[$findings]" '{pvcs_missing_storageclass:$findings}')"
count="$(jq '.pvcs_missing_storageclass | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No PVCs missing storageClassName found."
  else
    echo "PersistentVolumeClaims missing storageClassName (count=$count):"
    jq -r '.pvcs_missing_storageclass[] | "- \(.namespace)/\(.name) status=\(.status)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
