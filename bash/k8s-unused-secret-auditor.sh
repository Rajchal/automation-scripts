#!/usr/bin/env bash
set -euo pipefail

# k8s-unused-secret-auditor.sh
# Detect Secrets that are not referenced by any Pod in the same namespace.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans Secrets and Pods across all namespaces.
  - Finds Secrets that are not mounted as volumes or referenced via envFrom in any pod.

Examples:
  bash/k8s-unused-secret-auditor.sh
  bash/k8s-unused-secret-auditor.sh --output json
  bash/k8s-unused-secret-auditor.sh --output json --no-fail
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

secrets_json="$(kubectl get secret --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
pods_json="$(kubectl get pods --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"

used_secrets="$(jq -r '
  .items[]?
  | .metadata.namespace as $ns
  | (.spec.volumes // [])[]? | select(.secret != null) | "\($ns)/\(.secret.secretName)"
  , (.spec.containers // [])[]? | (.envFrom // [])[]? | select(.secretRef != null) | "\($ns)/\(.secretRef.name)"
  , (.spec.initContainers // [])[]? | (.envFrom // [])[]? | select(.secretRef != null) | "\($ns)/\(.secretRef.name)"
' <<< "$pods_json" | sort -u)

if [[ -z "$used_secrets" ]]; then
  used_secrets_json="[]"
else
  used_secrets_json="$(printf '%s\n' "$used_secrets" | jq -R . | jq -s .)"
fi

findings="$(jq -c --argjson used "$used_secrets_json" '
  .items[]?
  | {namespace:.metadata.namespace, name:.metadata.name}
  | select((.namespace + "/" + .name) as $k | $used | index($k) | not)
' <<< "$secrets_json")"

result="$(jq -n --argjson findings "[$findings]" '{unused_secrets:$findings}')"
count="$(jq '.unused_secrets | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No unused Secrets detected."
  else
    echo "Unused Secrets (count=$count):"
    jq -r '.unused_secrets[] | "- \(.namespace)/\(.name)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
