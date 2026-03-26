#!/usr/bin/env bash
set -euo pipefail

# k8s-pv-reclaim-policy-auditor.sh
# Detect PersistentVolumes with reclaimPolicy set to Retain (non-auto cleanup risk).

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Finds PVs with reclaimPolicy=Retain.
  - Retain policy can cause stale PVs/PVCs to remain after workload deletion.

Examples:
  bash/k8s-pv-reclaim-policy-auditor.sh
  bash/k8s-pv-reclaim-policy-auditor.sh --output json
  bash/k8s-pv-reclaim-policy-auditor.sh --output json --no-fail
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

pvs_json="$(kubectl get pv -o json 2>/dev/null || echo '{"items":[]}')"
findings="$(jq -c '.items[]? | select(.spec.claimRef != null and .spec.persistentVolumeReclaimPolicy == "Retain") | {name:.metadata.name, capacity:.spec.capacity, storageClass:.spec.storageClassName, reclaimPolicy:.spec.persistentVolumeReclaimPolicy, status:.status.phase, claimRef:.spec.claimRef}' <<< "$pvs_json")"
result="$(jq -n --argjson finds "[$findings]" '{retain_pv:$finds}')"
count="$(jq '.retain_pv | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No bound PVs with reclaimPolicy=Retain found."
  else
    echo "PersistentVolumes with reclaimPolicy=Retain (count=$count):"
    jq -r '.retain_pv[] | "- \(.name) status=\(.status) storageClass=\(.storageClass) capacity=\(.capacity) claim=\(.claimRef.namespace)/\(.claimRef.name)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
