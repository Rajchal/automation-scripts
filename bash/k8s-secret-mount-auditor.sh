#!/usr/bin/env bash
set -euo pipefail

# k8s-secret-mount-auditor.sh
# Detect pods that mount secrets as volumes or reference secrets via envFrom.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans all pods and reports those with secret volumes or secret refs in envFrom.
  - Useful for identifying workloads that rely on Kubernetes Secret data.

Examples:
  bash/k8s-secret-mount-auditor.sh
  bash/k8s-secret-mount-auditor.sh --output json
  bash/k8s-secret-mount-auditor.sh --output json --no-fail
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
  | {namespace:.metadata.namespace, name:.metadata.name, spec:.spec}
  | {secretVolumes:(.spec.volumes // [] | map(select(.secret != null) | .name)), secretEnvContainers:(.spec.containers // [] | map(select((.envFrom // [])[]? | .secretRef != null) | .name)), secretEnvInitContainers:(.spec.initContainers // [] | map(select((.envFrom // [])[]? | .secretRef != null) | .name))}
  | select((.secretVolumes | length) + (.secretEnvContainers | length) + (.secretEnvInitContainers | length) > 0)
' <<< "$pods_json")"

result="$(jq -n --argjson findings "[$findings]" '{pods_with_secret_mounts:$findings}')"
count="$(jq '.pods_with_secret_mounts | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No pods with secret mounts or secret envFrom refs found."
  else
    echo "Pods with secret mounts or secret refs (count=$count):"
    jq -r '.pods_with_secret_mounts[] | "- \(.namespace)/\(.name) volumes=\(.secretVolumes | join(",")) envContainers=\(.secretEnvContainers | join(",")) initContainers=\(.secretEnvInitContainers | join(","))"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
