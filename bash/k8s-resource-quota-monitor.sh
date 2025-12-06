#!/usr/bin/env bash
set -euo pipefail

# k8s-resource-quota-monitor.sh
# Monitor Kubernetes resource quotas and alert when namespaces approach limits.
# Shows CPU, memory, and pod count usage vs limits.
# Dry-run by default; use --no-dry-run to enable monitoring.

usage(){
  cat <<EOF
Usage: $0 [--namespace NS] [--threshold PERCENT] [--context CONTEXT] [--no-dry-run]

Options:
  --namespace NS           Monitor specific namespace (default: all namespaces with quotas)
  --threshold PERCENT      Alert threshold percentage (default: 80)
  --context CONTEXT        Kubernetes context to use
  --no-dry-run             Enable monitoring (default: dry-run)
  -h, --help               Show this help

Examples:
  # Dry-run: show what would be monitored
  bash/k8s-resource-quota-monitor.sh

  # Monitor all namespaces, alert at 75% usage
  bash/k8s-resource-quota-monitor.sh --threshold 75 --no-dry-run

  # Monitor specific namespace
  bash/k8s-resource-quota-monitor.sh --namespace production --no-dry-run

EOF
}

NAMESPACE=""
THRESHOLD=80
CONTEXT=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2;;
    --threshold) THRESHOLD="$2"; shift 2;;
    --context) CONTEXT="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required"; exit 3
fi

KUBECTL=(kubectl)
if [[ -n "$CONTEXT" ]]; then
  KUBECTL+=(--context "$CONTEXT")
fi

echo "K8s Resource Quota Monitor: namespace=${NAMESPACE:-all} threshold=${THRESHOLD}% dry-run=$DRY_RUN"

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: would monitor resource quotas in Kubernetes cluster"
  exit 0
fi

# Get namespaces to monitor
if [[ -n "$NAMESPACE" ]]; then
  namespaces=("$NAMESPACE")
else
  mapfile -t namespaces < <("${KUBECTL[@]}" get resourcequotas --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[].metadata.namespace' | sort -u)
fi

if [[ ${#namespaces[@]} -eq 0 ]]; then
  echo "No resource quotas found"
  exit 0
fi

echo "Monitoring ${#namespaces[@]} namespace(s) with resource quotas"
echo ""

declare -i alert_count=0

for ns in "${namespaces[@]}"; do
  echo "=== Namespace: $ns ==="
  
  quotas_json=$("${KUBECTL[@]}" get resourcequota -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
  mapfile -t quotas < <(echo "$quotas_json" | jq -c '.items[]?')
  
  if [[ ${#quotas[@]} -eq 0 ]]; then
    echo "  No resource quotas"
    continue
  fi
  
  for quota in "${quotas[@]}"; do
    quota_name=$(echo "$quota" | jq -r '.metadata.name')
    echo "  Quota: $quota_name"
    
    # Extract resources
    resources=$(echo "$quota" | jq -r '.status | to_entries[] | select(.key == "hard" or .key == "used") | .key + ":" + (.value | tostring)')
    
    # Parse hard and used limits
    declare -A hard used
    
    while IFS=: read -r key value; do
      if [[ "$key" == "hard" ]]; then
        while IFS='=' read -r resource limit; do
          hard["$resource"]="$limit"
        done < <(echo "$value" | jq -r 'to_entries[] | .key + "=" + .value')
      elif [[ "$key" == "used" ]]; then
        while IFS='=' read -r resource current; do
          used["$resource"]="$current"
        done < <(echo "$value" | jq -r 'to_entries[] | .key + "=" + .value')
      fi
    done <<< "$resources"
    
    # Check each resource
    for resource in "${!hard[@]}"; do
      limit="${hard[$resource]}"
      current="${used[$resource]:-0}"
      
      # Convert to numeric if possible (strip units for comparison)
      limit_num=$(echo "$limit" | grep -oE '[0-9]+' || echo "0")
      current_num=$(echo "$current" | grep -oE '[0-9]+' || echo "0")
      
      if [[ $limit_num -gt 0 ]]; then
        usage_percent=$((current_num * 100 / limit_num))
        
        status="✓"
        if [[ $usage_percent -ge $THRESHOLD ]]; then
          status="⚠️ ALERT"
          ((alert_count++))
        fi
        
        echo "    $status $resource: $current / $limit (${usage_percent}%)"
      else
        echo "    - $resource: $current / $limit"
      fi
    done
    
    unset hard used
    echo ""
  done
done

echo "=== Summary ==="
echo "Total alerts: $alert_count"

if [[ $alert_count -gt 0 ]]; then
  echo "⚠️  Some namespaces are approaching quota limits!"
  exit 1
else
  echo "✓ All quotas within threshold"
  exit 0
fi
