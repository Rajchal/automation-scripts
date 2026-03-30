#!/usr/bin/env bash
set -euo pipefail

# k8s-image-pull-secret-auditor.sh
# Detect pods that do not define spec.imagePullSecrets (may fail pulling from private registries).

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans all running pods and reports ones with no imagePullSecrets set.
  - Use this to find workload created without explicit registry credentials configuration.

Examples:
  bash/k8s-image-pull-secret-auditor.sh
  bash/k8s-image-pull-secret-auditor.sh --output json
  bash/k8s-image-pull-secret-auditor.sh --output json --no-fail
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

pods_json="$(kubectl get pods --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
findings="$(jq -c '.items[]? | select(.spec.imagePullSecrets == null or (.spec.imagePullSecrets | length == 0)) | {namespace:.metadata.namespace, name:.metadata.name, serviceAccount:(.spec.serviceAccountName // "default"), phase:.status.phase}' <<< "$pods_json")"

result="$(jq -n --argjson findings "[$findings]" '{pods_missing_imagePullSecrets:$findings}')"
count="$(jq '.pods_missing_imagePullSecrets | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No pods missing imagePullSecrets.";
  else
    echo "Pods missing imagePullSecrets (count=$count):"
    jq -r '.pods_missing_imagePullSecrets[] | "- \(.namespace)/\(.name) sa=\(.serviceAccount) phase=\(.phase)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
