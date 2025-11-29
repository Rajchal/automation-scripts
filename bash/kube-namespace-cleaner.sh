#!/usr/bin/env bash
set -euo pipefail

# Safely clean completed jobs and evicted pods in a Kubernetes namespace older than X days.
# Dry-run by default.
# Usage: kube-namespace-cleaner.sh -n NAMESPACE -d DAYS [--dry-run]

usage(){
  cat <<EOF
Usage: $0 -n NAMESPACE -d DAYS [--dry-run]

Options:
  -n NAMESPACE   Kubernetes namespace
  -d DAYS        Age threshold in days for resources to delete
  --dry-run      Show kubectl commands without executing (default)
  --no-dry-run   Execute deletions
  -h             Help
EOF
}

NS=""
DAYS=0
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NS="$2"; shift 2;;
    -d) DAYS="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown $1"; usage; exit 2;;
  esac
done

if [[ -z "$NS" || $DAYS -le 0 ]]; then
  usage; exit 2
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl required"; exit 3
fi

cutoff_date=$(date -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)
echo "Namespace: $NS; deleting completed/evicted resources older than $cutoff_date"

echo "Checking completed jobs..."
jobs=$(kubectl get jobs -n "$NS" --field-selector status.successful==1 -o json)
echo "$jobs" | jq -r '.items[] | "\(.metadata.name) \(.status.completionTime)"' | while read -r name completion; do
  if [[ "$completion" == "null" ]]; then
    continue
  fi
  if [[ "$(date -d "$completion" +%s)" -lt "$(date -d "$cutoff_date" +%s)" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "DRY RUN: kubectl delete job $name -n $NS"
    else
      kubectl delete job "$name" -n "$NS"
      echo "Deleted job $name"
    fi
  fi
done

echo "Cleaning evicted pods..."
kubectl get pods -n "$NS" --field-selector status.phase==Failed -o json | jq -r '.items[] | select(.status.reason=="Evicted") | .metadata.name' | while read -r pod; do
  if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN: kubectl delete pod $pod -n $NS"
  else
    kubectl delete pod "$pod" -n "$NS"
    echo "Deleted pod $pod"
  fi
done

echo "Done."
