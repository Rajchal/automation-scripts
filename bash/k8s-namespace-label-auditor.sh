#!/usr/bin/env bash
set -euo pipefail

# k8s-namespace-label-auditor.sh
# Detect namespaces missing standard metadata labels like environment and owner.

usage() {
  cat <<EOF
Usage: $0 [--labels label1,label2,...] [--output text|json] [--no-fail]

Options:
  --labels LABELS    Comma-separated labels to require on namespaces (default: environment,owner)
  --output FORMAT    text (default) or json
  --no-fail          Exit 0 even when findings are present
  -h, --help         Show this help

Notes:
  - Scans all namespaces for required labels.
  - Helps enforce namespace metadata hygiene for environment and ownership.

Examples:
  bash/k8s-namespace-label-auditor.sh
  bash/k8s-namespace-label-auditor.sh --labels environment,team --output json
  bash/k8s-namespace-label-auditor.sh --output json --no-fail
EOF
}

OUTPUT="text"
NO_FAIL=false
LABELS="environment,owner"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --labels)
      LABELS="${2:-}"; shift 2
      ;;
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

IFS=',' read -r -a required_labels <<< "$LABELS"

ns_json="$(kubectl get namespace -o json 2>/dev/null || echo '{"items":[]}')"
findings="$(jq -c --argjson required_labels "$(printf '%s
' "${required_labels[@]}" | jq -R . | jq -s .)" '
  .items[]?
  | {name:.metadata.name, labels:(.metadata.labels // {})}
  | {name, missing:([$required_labels[]? | select(. as $key | (.labels[$key] // null) | not)] | unique)}
  | select(.missing | length > 0)
' <<< "$ns_json")"

result="$(jq -n --argjson findings "[$findings]" '{namespaces_missing_labels:$findings}')"
count="$(jq '.namespaces_missing_labels | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "All namespaces contain the required labels."
  else
    echo "Namespaces missing required labels (count=$count):"
    jq -r '.namespaces_missing_labels[] | "- \(.name) missing=\(.missing | join(","))"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
