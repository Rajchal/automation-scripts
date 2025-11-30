#!/usr/bin/env bash
set -euo pipefail

# Audit EC2 instances for low CPU activity over a time window using CloudWatch.
# Dry-run by default; optionally stop low-activity instances when explicitly asked.
# Usage: aws-ec2-idle-instance-auditor.sh [--region REGION] [--days N] [--cpu-threshold PERCENT] [--stop] [--no-dry-run]

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--cpu-threshold PERCENT] [--stop] [--no-dry-run]

Options:
  --region REGION        AWS region (optional; uses AWS_DEFAULT_REGION if unset)
  --days N               Evaluate average CPU over the last N days (default: 7)
  --cpu-threshold N      Percent CPU threshold to consider idle (default: 5)
  --stop                 Stop instances identified as idle (requires --no-dry-run)
  --dry-run              Don't perform destructive actions (default)
  --no-dry-run           Allow actions (requires explicit --stop to take effect)
  -h, --help             Show this help

Example (dry-run):
  bash/aws-ec2-idle-instance-auditor.sh --days 7 --cpu-threshold 3

To stop candidates (use with caution):
  bash/aws-ec2-idle-instance-auditor.sh --days 7 --cpu-threshold 3 --stop --no-dry-run

EOF
}

REGION=""
DAYS=7
CPU_THRESH=5
DO_STOP=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --cpu-threshold) CPU_THRESH="$2"; shift 2;;
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

AWS_BASE=(aws ec2)
CW_BASE=(aws cloudwatch)
if [[ -n "$REGION" ]]; then
  AWS_BASE+=(--region "$REGION")
  CW_BASE+=(--region "$REGION")
fi

echo "Audit settings: days=$DAYS cpu-threshold=$CPU_THRESH% stop=$DO_STOP dry-run=$DRY_RUN"

# Compute start and end times for CloudWatch query
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_TIME=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)

echo "Querying instances..."
instance_ids=$(${AWS_BASE[*]} describe-instances --filters "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].InstanceId' --output text)

if [[ -z "$instance_ids" ]]; then
  echo "No running instances found."; exit 0
fi

candidates=()

for iid in $instance_ids; do
  # Request average CPU over the period; use 1h period and compute average of averages
  resp=$(${CW_BASE[*]} get-metric-statistics --metric-name CPUUtilization --namespace AWS/EC2 --statistics Average --period 3600 --start-time "$START_TIME" --end-time "$END_TIME" --dimensions Name=InstanceId,Value=$iid --output json)
  # Extract datapoints and compute overall average
  avg=$(echo "$resp" | jq -r '[.Datapoints[].Average] | if length==0 then "null" else (add / length) end')
  if [[ "$avg" == "null" ]]; then
    echo "Instance $iid: no CPU datapoints found; skipping"
    continue
  fi
  avg_rounded=$(printf "%.2f" "$avg")
  echo "Instance $iid: avg CPU=${avg_rounded}% over last ${DAYS}d"
  # Compare with threshold
  comp=$(awk -v a="$avg" -v t="$CPU_THRESH" 'BEGIN{ print (a < t) ? 1 : 0 }')
  if [[ "$comp" -eq 1 ]]; then
    candidates+=("$iid:$avg_rounded")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No idle instances found (threshold ${CPU_THRESH}%)."; exit 0
fi

echo "\nIdle instance candidates (avg CPU < ${CPU_THRESH}%):"
for c in "${candidates[@]}"; do
  iid=${c%%:*}
  avg=${c#*:}
  echo " - $iid (avg CPU ${avg}%)"
done

if [[ "$DO_STOP" == false ]]; then
  echo "\nNo destructive action requested. To stop these instances, re-run with --stop --no-dry-run"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: would stop the instances listed above. Re-run with --no-dry-run to perform the stop."
  exit 0
fi

echo "\nStopping idle instances..."
for c in "${candidates[@]}"; do
  iid=${c%%:*}
  echo "Stopping $iid"
  ${AWS_BASE[*]} stop-instances --instance-ids "$iid"
done

echo "Done."
