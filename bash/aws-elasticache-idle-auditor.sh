#!/usr/bin/env bash
set -euo pipefail

# Audit ElastiCache clusters/replication-groups for low activity.
# Dry-run by default. Tagging requires --tag --no-dry-run.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--cpu-threshold PERCENT] [--conn-threshold N] [--tag] [--no-dry-run]

Options:
  --region REGION        AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N               Lookback window in days for CloudWatch metrics (default: 14)
  --cpu-threshold PCT    Consider idle if avg CPU <= PCT (default: 5)
  --conn-threshold N     Consider idle if avg CurrConnections <= N (default: 5)
  --tag                  Tag candidate resources with Key=idle_candidate,Value=true
  --dry-run              Default; only print actions
  --no-dry-run           Perform tagging when requested
  -h, --help             Show this help

Example (dry-run):
  bash/aws-elasticache-idle-auditor.sh --days 14 --cpu-threshold 5 --conn-threshold 3

To tag candidates:
  bash/aws-elasticache-idle-auditor.sh --tag --no-dry-run

EOF
}

REGION=""
DAYS=14
CPU_THRESHOLD=5
CONN_THRESHOLD=5
DO_TAG=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --cpu-threshold) CPU_THRESHOLD="$2"; shift 2;;
    --conn-threshold) CONN_THRESHOLD="$2"; shift 2;;
    --tag) DO_TAG=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required"; exit 3
fi

AWS=(aws)
CW=(aws cloudwatch)
EL=(aws elasticache)
if [[ -n "$REGION" ]]; then
  AWS+=(--region "$REGION")
  CW+=(--region "$REGION")
  EL+=(--region "$REGION")
fi

echo "ElastiCache auditor: days=$DAYS cpu_th=$CPU_THRESHOLD% conn_th=$CONN_THRESHOLD tag=$DO_TAG dry-run=$DRY_RUN"

end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_time=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)

echo "Listing cache clusters..."
clusters=$(${EL[*]} describe-cache-clusters --show-cache-node-info --query 'CacheClusters[].[CacheClusterId,ReplicationGroupId,CacheClusterStatus]' --output json)
mapfile -t cluster_list < <(echo "$clusters" | jq -r '.[] | @base64')

if [[ ${#cluster_list[@]} -eq 0 ]]; then
  echo "No ElastiCache clusters found."; exit 0
fi

declare -a candidates

for item in "${cluster_list[@]}"; do
  rec=$(echo "$item" | base64 --decode | jq -r '.')
  cluster_id=$(echo "$rec" | jq -r '.[0]')
  rep_group=$(echo "$rec" | jq -r '.[1] // empty')
  status=$(echo "$rec" | jq -r '.[2]')

  if [[ "$status" != "available" && "$status" != "available" ]]; then
    echo "Skipping $cluster_id (status=$status)"
    continue
  fi

  echo "Checking cluster $cluster_id (replication_group=$rep_group)"

  # CPU average over window
  resp_cpu=$(${CW[*]} get-metric-statistics --namespace AWS/ElastiCache --metric-name CPUUtilization --statistics Average --period 3600 --start-time "$start_time" --end-time "$end_time" --dimensions Name=CacheClusterId,Value=$cluster_id --output json 2>/dev/null || echo '{}')
  cpu_avg=$(echo "$resp_cpu" | jq -r '[.Datapoints[].Average] | if length==0 then 0 else (add / length) end')
  cpu_avg=${cpu_avg:-0}
  cpu_avg_fmt=$(printf "%.2f" "$cpu_avg")

  # CurrConnections average over window
  resp_conn=$(${CW[*]} get-metric-statistics --namespace AWS/ElastiCache --metric-name CurrConnections --statistics Average --period 3600 --start-time "$start_time" --end-time "$end_time" --dimensions Name=CacheClusterId,Value=$cluster_id --output json 2>/dev/null || echo '{}')
  conn_avg=$(echo "$resp_conn" | jq -r '[.Datapoints[].Average] | if length==0 then 0 else (add / length) end')
  conn_avg=${conn_avg:-0}
  conn_avg_fmt=$(printf "%.2f" "$conn_avg")

  echo "  avg CPU=${cpu_avg_fmt}% avg CurrConnections=${conn_avg_fmt}"

  cpu_check=$(awk -v v="$cpu_avg" -v t="$CPU_THRESHOLD" 'BEGIN{print (v <= t) ? 1 : 0}')
  conn_check=$(awk -v v="$conn_avg" -v t="$CONN_THRESHOLD" 'BEGIN{print (v <= t) ? 1 : 0}')

  if [[ $cpu_check -eq 1 && $conn_check -eq 1 ]]; then
    candidates+=("$cluster_id:$rep_group:$cpu_avg_fmt:$conn_avg_fmt")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No idle ElastiCache clusters found."; exit 0
fi

echo "\nCandidate idle clusters:"
for c in "${candidates[@]}"; do
  cid=${c%%:*}
  rest=${c#*:}
  rg=${rest%%:*}
  rest2=${rest#*:}
  cpu=${rest2%%:*}
  conn=${rest2#*:}
  name="$cid"
  if [[ -n "$rg" && "$rg" != "null" ]]; then name="$rg ($cid)"; fi
  echo " - $name cpu=${cpu}% conn=${conn}"
done

if [[ "$DO_TAG" == false ]]; then
  echo "\nNo action requested. To tag these clusters re-run with --tag --no-dry-run"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: would tag the candidate clusters with Key=idle_candidate,Value=true. Re-run with --no-dry-run to apply."
  exit 0
fi

for c in "${candidates[@]}"; do
  cid=${c%%:*}
  echo "Tagging $cid: idle_candidate=true"
  # Try to get resource ARN for tagging
  arn=$(${EL[*]} describe-cache-clusters --cache-cluster-id "$cid" --query 'CacheClusters[0].ARN' --output text 2>/dev/null || echo 'None')
  if [[ -z "$arn" || "$arn" == "None" ]]; then
    # try replication group
    rg=$(${EL[*]} describe-cache-clusters --cache-cluster-id "$cid" --query 'CacheClusters[0].ReplicationGroupId' --output text 2>/dev/null || echo '')
    if [[ -n "$rg" && "$rg" != "None" ]]; then
      arn=$(${EL[*]} describe-replication-groups --replication-group-id "$rg" --query 'ReplicationGroups[0].ARN' --output text 2>/dev/null || echo 'None')
    fi
  fi

  if [[ -n "$arn" && "$arn" != "None" ]]; then
    ${EL[*]} add-tags-to-resource --resource-name "$arn" --tags Key=idle_candidate,Value=true
  else
    echo "  Could not determine ARN for $cid; skipping tag. Consider tagging via console or resource ARN.";
  fi
done

echo "Done."
