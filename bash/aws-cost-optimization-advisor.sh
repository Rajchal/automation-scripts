#!/usr/bin/env bash
set -euo pipefail

# aws-cost-optimization-advisor.sh
# Analyze RDS instances and compute costs; recommend downsizing or termination based on utilization.
# Uses CloudWatch metrics (CPU, Database Connections) to identify underutilized instances.
# Dry-run by default; reports recommendations only.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--cpu-threshold PCT] [--connection-threshold N] [--no-dry-run]

Options:
  --region REGION              AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N                     Lookback window in days (default: 30)
  --cpu-threshold PCT          Consider instances with avg CPU below PCT as underutilized (default: 5)
  --connection-threshold N     Consider instances with avg connections below N as underutilized (default: 2)
  --no-dry-run                 Generate CSV report (default dry-run is console report only)
  -h, --help                   Show this help

Examples:
  # Dry-run: identify underutilized RDS instances
  bash/aws-cost-optimization-advisor.sh --days 30

  # Identify instances with CPU < 10% and connections < 5
  bash/aws-cost-optimization-advisor.sh --cpu-threshold 10 --connection-threshold 5

EOF
}

REGION=""
DAYS=30
CPU_THRESHOLD=5
CONNECTION_THRESHOLD=2
DRY_RUN=true
REPORT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --cpu-threshold) CPU_THRESHOLD="$2"; shift 2;;
    --connection-threshold) CONNECTION_THRESHOLD="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; REPORT_FILE="cost-optimization-report-$(date +%s).csv"; shift;;
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

echo "Cost optimization advisor: days=$DAYS cpu-threshold=$CPU_THRESHOLD connection-threshold=$CONNECTION_THRESHOLD dry-run=$DRY_RUN"

# Get all RDS instances
instances_json=$("${RDS[@]}" describe-db-instances --output json 2>/dev/null || echo '{}')
mapfile -t instances < <(echo "$instances_json" | jq -c '.DBInstances[]?')

if [[ ${#instances[@]} -eq 0 ]]; then
  echo "No RDS instances found."; exit 0
fi

now_epoch=$(date +%s)
start_time=$((now_epoch - DAYS*24*3600))
start_iso=$(date -u -d @$start_time +%Y-%m-%dT%H:%M:%SZ)
end_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

declare -a recommendations

for inst in "${instances[@]}"; do
  id=$(echo "$inst" | jq -r '.DBInstanceIdentifier')
  class=$(echo "$inst" | jq -r '.DBInstanceClass')
  engine=$(echo "$inst" | jq -r '.Engine')
  allocated=$(echo "$inst" | jq -r '.AllocatedStorage // 0')
  multi_az=$(echo "$inst" | jq -r '.MultiAZ // false')

  # Get CPU utilization
  cpu_stats=$("${CW[@]}" get-metric-statistics --namespace AWS/RDS --metric-name CPUUtilization \
    --dimensions Name=DBInstanceIdentifier,Value="$id" \
    --start-time "$start_iso" --end-time "$end_iso" --period 3600 --statistics Average \
    --output json 2>/dev/null || echo '{}')
  cpu_avg=$(echo "$cpu_stats" | jq '[.Datapoints[]?.Average] | add / length' 2>/dev/null || echo 0)

  # Get database connections
  conn_stats=$("${CW[@]}" get-metric-statistics --namespace AWS/RDS --metric-name DatabaseConnections \
    --dimensions Name=DBInstanceIdentifier,Value="$id" \
    --start-time "$start_iso" --end-time "$end_iso" --period 3600 --statistics Average \
    --output json 2>/dev/null || echo '{}')
  conn_avg=$(echo "$conn_stats" | jq '[.Datapoints[]?.Average] | add / length' 2>/dev/null || echo 0)

  recommendation="MONITOR"
  if (( $(echo "$cpu_avg < $CPU_THRESHOLD" | bc -l) )) && (( $(echo "$conn_avg < $CONNECTION_THRESHOLD" | bc -l) )); then
    recommendation="DOWNSIZE_OR_TERMINATE"
  elif (( $(echo "$cpu_avg < $CPU_THRESHOLD" | bc -l) )); then
    recommendation="DOWNSIZE"
  fi

  echo "$id ($class) - CPU: ${cpu_avg}% Connections: $(printf "%.1f" "$conn_avg") - $recommendation"
  recommendations+=("$id|$class|$engine|$allocated|$multi_az|${cpu_avg}|${conn_avg}|$recommendation")
done

if [[ "$DRY_RUN" == false && -n "$REPORT_FILE" ]]; then
  echo ""
  echo "Writing CSV report to: $REPORT_FILE"
  {
    echo "InstanceID,InstanceClass,Engine,AllocatedStorageGB,MultiAZ,AvgCPU%,AvgConnections,Recommendation"
    for rec in "${recommendations[@]}"; do
      echo "$rec" | tr '|' ','
    done
  } > "$REPORT_FILE"
  echo "Report generated: $(wc -l < "$REPORT_FILE") entries"
fi

echo "Done."
