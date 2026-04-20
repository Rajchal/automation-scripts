#!/usr/bin/env bash
set -euo pipefail

# k8s-configmap-mount-auditor.sh
# Detect pods mounting ConfigMaps as volumes or referencing them via envFrom.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans all pods and reports those that use ConfigMaps in volumes or envFrom.
  - Useful for identifying workloads that depend on ConfigMap data.

Examples:
  bash/k8s-configmap-mount-auditor.sh
  bash/k8s-configmap-mount-auditor.sh --output json
  bash/k8s-configmap-mount-auditor.sh --output json --no-fail
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
findings="$(jq -c '
  .items[]?
  | {namespace:.metadata.namespace, name:.metadata.name, configMapVolumes:(.spec.volumes // [] | map(select(.configMap != null) | .configMap.name)), configMapEnv:(.spec.containers // [] | map(.envFrom // [] | select(.configMapRef != null) | .configMapRef.name) | add // []), initConfigMapEnv:(.spec.initContainers // [] | map(.envFrom // [] | select(.configMapRef != null) | .configMapRef.name) | add // [])}
  | select((.configMapVolumes | length > 0) or (.configMapEnv | length > 0) or (.initConfigMapEnv | length > 0))
' <<< "$pods_json")"

result="$(jq -n --argjson findings "[$findings]" '{pods_using_configmaps:$findings}')"
count="$(jq '.pods_using_configmaps | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No pods using ConfigMaps found."
  else
    echo "Pods using ConfigMaps (count=$count):"
    jq -r '.pods_using_configmaps[] | "- \(.namespace)/\(.name) volumes=\(.configMapVolumes | join(",")) env=\(.configMapEnv | join(",")) initEnv=\(.initConfigMapEnv | join(","))"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
