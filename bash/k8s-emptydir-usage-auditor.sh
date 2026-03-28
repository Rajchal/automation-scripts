#!/usr/bin/env bash
set -euo pipefail

# k8s-emptydir-usage-auditor.sh
# Detect pods using hostPath or emptyDir volumes, which may expose host filesystem or volatile local storage.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Detects pods with any emptyDir volume or hostPath volume.
  - This is intended for security hygiene reviews of pod volume scope.

Examples:
  bash/k8s-emptydir-usage-auditor.sh
  bash/k8s-emptydir-usage-auditor.sh --output json
  bash/k8s-emptydir-usage-auditor.sh --output json --no-fail
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
findings="$(jq -c '.items[]? | {namespace:.metadata.namespace, name:.metadata.name, volumes:.spec.volumes} | select(.volumes != null) | select(.volumes[]? | .emptyDir != null or .hostPath != null) | {namespace:.namespace, name:.name, volumes:(.volumes | map(select(.emptyDir != null or .hostPath != null) | {name:.name, emptyDir:.emptyDir, hostPath:.hostPath}))}' <<< "$pods_json")"
result="$(jq -n --argjson findings "[$findings]" '{pods_with_emptydir_or_hostpath:$findings}')"
count="$(jq '.pods_with_emptydir_or_hostpath | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No pods using emptyDir or hostPath volumes found."
  else
    echo "Pods using emptyDir or hostPath volumes (count=$count):"
    jq -r '.pods_with_emptydir_or_hostpath[] | "- \(.namespace)/\(.name) volumes=\(.volumes | map(.name + (if .hostPath then "(hostPath=" + .hostPath.path + ")" elif .emptyDir then "(emptyDir)" else "" end)) | join(","))"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
