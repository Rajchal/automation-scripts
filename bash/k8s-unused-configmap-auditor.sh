#!/usr/bin/env bash
set -euo pipefail

# k8s-unused-configmap-auditor.sh
# Identify ConfigMaps not referenced by any pod in the same namespace.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - This script finds ConfigMaps that are not mounted or envFrom referenced by any pod in their namespace.

Examples:
  bash/k8s-unused-configmap-auditor.sh
  bash/k8s-unused-configmap-auditor.sh --output json
  bash/k8s-unused-configmap-auditor.sh --output json --no-fail
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

cms_json="$(kubectl get configmap --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
pods_json="$(kubectl get pods --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"

used_cm_keys="$(jq -r '
  .items[]?
  | .metadata.namespace as $ns
  | .spec.volumes[]? | select(.configMap != null) | "\($ns)/\(.configMap.name)"
  , .spec.containers[]? | .envFrom[]? | select(.configMapRef != null) | "\($ns)/\(.configMapRef.name)"
  , .spec.initContainers[]? | .envFrom[]? | select(.configMapRef != null) | "\($ns)/\(.configMapRef.name)"
' <<< "$pods_json" | sort -u)

if [[ -z "$used_cm_keys" ]]; then
  used_cm_keys_json="[]"
else
  used_cm_keys_json="$(printf '%s\n' "$used_cm_keys" | jq -R . | jq -s .)"
fi

findings_json="$(jq -c '
  .items[]?
  | {namespace:.metadata.namespace, name:.metadata.name}
  | select((.namespace + "/" + .name) as $k | ($used | index($k) | not))
' --argjson used "$used_cm_keys_json" <<< "$cms_json" | jq -s '.')"

result="$(jq -n --argjson findings "$findings_json" '{unused_configmaps:$findings}')"
count="$(jq '.unused_configmaps | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No unused ConfigMaps detected."
  else
    echo "Unused ConfigMaps (count=$count):"
    jq -r '.unused_configmaps[] | "- " + .namespace + "/" + .name' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
