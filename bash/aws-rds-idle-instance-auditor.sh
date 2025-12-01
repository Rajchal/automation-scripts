#!/usr/bin/env bash
set -euo pipefail

# Audit RDS DB instances for low activity (CPU + connections) and optionally stop them.
# Dry-run by default.
# Usage: aws-rds-idle-instance-auditor.sh [--region REGION] [--days N] [--cpu-threshold PERCENT] [--conn-threshold N] [--stop] [--no-dry-run]

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--cpu-threshold PERCENT] [--conn-threshold N] [--stop] [--no-dry-run]

Options:
  --region REGION        AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N               Lookback window in days for CloudWatch metrics (default: 7)
  --cpu-threshold PCT   CPU percent threshold to consider idle (default: 5)
  --conn-threshold N    DB connections threshold to consider idle (default: 5)
  --stop                 Stop RDS instances identified as idle (requires --no-dry-run)
  --dry-run              Default; only print actions
  --no-dry-run           Perform actions
  -h, --help             Show this help

Notes:
  - Aurora clusters and read replicas may require different handling; this script targets single-instance RDS DBInstances.
  - Stopping some RDS engines may not be supported; the script will skip unsupported instances and list them.

Example (dry-run):
  bash/aws-rds-idle-instance-auditor.sh --days 7 --cpu-threshold 3 --conn-threshold 2

To stop candidates:
  bash/aws-rds-idle-instance-auditor.sh --days 7 --cpu-threshold 3 --conn-threshold 2 --stop --no-dry-run

EOF
}

REGION=""
DAYS=7
CPU_THRESH=5
CONN_THRESH=5
DO_STOP=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --cpu-threshold) CPU_THRESH="$2"; shift 2;;
    --conn-threshold) CONN_THRESH="$2"; shift 2;;
    --stop) DO_STOP=true; shift;;
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

RDS=(aws rds)
CW=(aws cloudwatch)
if [[ -n "$REGION" ]]; then
  RDS+=(--region "$REGION")
  CW+=(--region "$REGION")
fi

echo "RDS auditor: days=$DAYS cpu-threshold=${CPU_THRESH}% conn-threshold=${CONN_THRESH} stop=$DO_STOP dry-run=$DRY_RUN"

end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_time=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)

echo "Listing RDS DB instances..."
dbs_json=$(${RDS[*]} describe-db-instances --query 'DBInstances[].[DBInstanceIdentifier,Engine,DBInstanceStatus,DBInstanceClass,MultiAZ]' --output json)
mapfile -t db_list < <(echo "$dbs_json" | jq -r '.[] | @base64')

if [[ ${#db_list[@]} -eq 0 ]]; then
  echo "No RDS DB instances found."; exit 0
fi

declare -a candidates

for b in "${db_list[@]}"; do
  rec=$(echo "$b" | base64 --decode | jq -r '.')
  id=$(echo "$rec" | jq -r '.[0]')
  engine=$(echo "$rec" | jq -r '.[1]')
  status=$(echo "$rec" | jq -r '.[2]')
  dbclass=$(echo "$rec" | jq -r '.[3]')
  multiaz=$(echo "$rec" | jq -r '.[4]')

  if [[ "$status" != "available" && "$status" != "stopped" ]]; then
    echo "Skipping $id: status=$status"
    continue
  fi

  # Skip Aurora clusters (engine starts with aurora)
  if [[ "$engine" == aurora* ]]; then
    echo "Skipping $id (engine=$engine) — Aurora cluster handling not covered"
    continue
  fi

  echo "Checking $id (engine=$engine, class=$dbclass, status=$status)"

  # CPU average
  resp_cpu=$(${CW[*]} get-metric-statistics --namespace AWS/RDS --metric-name CPUUtilization --statistics Average --period 3600 --start-time "$start_time" --end-time "$end_time" --dimensions Name=DBInstanceIdentifier,Value=$id --output json 2>/dev/null || echo '{}')
  cpu_avg=$(echo "$resp_cpu" | jq -r '[.Datapoints[].Average] | if length==0 then "null" else (add / length) end')
  if [[ "$cpu_avg" == "null" ]]; then
    echo "  No CPU datapoints for $id; skipping"
    continue
  fi
  cpu_avg=$(printf "%.2f" "$cpu_avg")

  # DB connections sum
  resp_conn=$(${CW[*]} get-metric-statistics --namespace AWS/RDS --metric-name DatabaseConnections --statistics Average --period 3600 --start-time "$start_time" --end-time "$end_time" --dimensions Name=DBInstanceIdentifier,Value=$id --output json 2>/dev/null || echo '{}')
  conn_avg=$(echo "$resp_conn" | jq -r '[.Datapoints[].Average] | if length==0 then "null" else (add / length) end')
  if [[ "$conn_avg" == "null" ]]; then
    conn_avg=0
  fi
  conn_avg=$(printf "%.2f" "$conn_avg")

  echo "  avg CPU=${cpu_avg}% over last ${DAYS}d; avg connections=${conn_avg}"

  # Check thresholds
  cpu_check=$(awk -v a="$cpu_avg" -v t="$CPU_THRESH" 'BEGIN{ print (a < t) ? 1 : 0 }')
  conn_check=$(awk -v c="$conn_avg" -v ct="$CONN_THRESH" 'BEGIN{ print (c < ct) ? 1 : 0 }')

  if [[ "$cpu_check" -eq 1 && "$conn_check" -eq 1 ]]; then
    candidates+=("$id:$cpu_avg:$conn_avg")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No idle RDS instances found."; exit 0
fi

echo "\nIdle RDS candidates (cpu < ${CPU_THRESH}% and connections < ${CONN_THRESH}):"
for c in "${candidates[@]}"; do
  id=${c%%:*}
  rest=${c#*:}
  cpu=${rest%%:*}
  conn=${rest#*:}
  echo " - $id (avg CPU=${cpu}%, avg connections=${conn})"
done

if [[ "$DO_STOP" == false ]]; then
  echo "\nNo destructive action requested. To stop these instances, re-run with --stop --no-dry-run"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: would stop the instances listed above. Re-run with --no-dry-run to perform stops."
  exit 0
fi

echo "\nStopping idle RDS instances..."
for c in "${candidates[@]}"; do
  id=${c%%:*}
  echo "Stopping RDS instance $id"
  ${RDS[*]} stop-db-instance --db-instance-identifier "$id" || echo "Failed to stop $id (maybe unsupported)"
done

echo "Done."
