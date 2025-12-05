#!/usr/bin/env bash
set -euo pipefail

# aws-lambda-health-monitor.sh
# Monitor Lambda function health by analyzing CloudWatch metrics:
# - Error count and rate
# - Throttles
# - Duration (p99 tail latency)
# Alerts on anomalies; dry-run by default.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--error-threshold N] [--throttle-threshold N] [--duration-p99-threshold MS] [--no-dry-run]

Options:
  --region REGION              AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N                     Lookback window in days (default: 7)
  --error-threshold N          Alert if error count > N in period (default: 10)
  --throttle-threshold N       Alert if throttles > N in period (default: 5)
  --duration-p99-threshold MS  Alert if p99 duration > MS milliseconds (default: 30000)
  --no-dry-run                 Send alerts (placeholder; would use SNS/email in production)
  -h, --help                   Show this help

Examples:
  # Dry-run: check all Lambda functions for health issues
  bash/aws-lambda-health-monitor.sh --days 7

  # Strict thresholds: alert on errors > 5, throttles > 2
  bash/aws-lambda-health-monitor.sh --error-threshold 5 --throttle-threshold 2

EOF
}

REGION=""
DAYS=7
ERROR_THRESHOLD=10
THROTTLE_THRESHOLD=5
DURATION_P99_THRESHOLD=30000
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --error-threshold) ERROR_THRESHOLD="$2"; shift 2;;
    --throttle-threshold) THROTTLE_THRESHOLD="$2"; shift 2;;
    --duration-p99-threshold) DURATION_P99_THRESHOLD="$2"; shift 2;;
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

LAMBDA=(aws lambda)
CW=(aws cloudwatch)
if [[ -n "$REGION" ]]; then
  LAMBDA+=(--region "$REGION")
  CW+=(--region "$REGION")
fi

echo "Lambda health monitor: days=$DAYS error-threshold=$ERROR_THRESHOLD throttle-threshold=$THROTTLE_THRESHOLD duration-p99=$DURATION_P99_THRESHOLD dry-run=$DRY_RUN"

# Get all Lambda functions
functions_json=$("${LAMBDA[@]}" list-functions --output json 2>/dev/null || echo '{}')
mapfile -t functions < <(echo "$functions_json" | jq -c '.Functions[]?')

if [[ ${#functions[@]} -eq 0 ]]; then
  echo "No Lambda functions found."; exit 0
fi

now_epoch=$(date +%s)
start_time=$((now_epoch - DAYS*24*3600))
start_iso=$(date -u -d @$start_time +%Y-%m-%dT%H:%M:%SZ)
end_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

declare -a alerts

for func in "${functions[@]}"; do
  name=$(echo "$func" | jq -r '.FunctionName')
  runtime=$(echo "$func" | jq -r '.Runtime // "unknown"')

  # Get error count
  error_stats=$("${CW[@]}" get-metric-statistics --namespace AWS/Lambda --metric-name Errors \
    --dimensions Name=FunctionName,Value="$name" \
    --start-time "$start_iso" --end-time "$end_iso" --period 3600 --statistics Sum \
    --output json 2>/dev/null || echo '{}')
  error_total=$(echo "$error_stats" | jq '[.Datapoints[]?.Sum] | add // 0' 2>/dev/null)

  # Get throttles count
  throttle_stats=$("${CW[@]}" get-metric-statistics --namespace AWS/Lambda --metric-name Throttles \
    --dimensions Name=FunctionName,Value="$name" \
    --start-time "$start_iso" --end-time "$end_iso" --period 3600 --statistics Sum \
    --output json 2>/dev/null || echo '{}')
  throttle_total=$(echo "$throttle_stats" | jq '[.Datapoints[]?.Sum] | add // 0' 2>/dev/null)

  # Get duration (p99 estimate via MaxValue)
  duration_stats=$("${CW[@]}" get-metric-statistics --namespace AWS/Lambda --metric-name Duration \
    --dimensions Name=FunctionName,Value="$name" \
    --start-time "$start_iso" --end-time "$end_iso" --period 3600 --statistics Maximum \
    --output json 2>/dev/null || echo '{}')
  duration_max=$(echo "$duration_stats" | jq '[.Datapoints[]?.Maximum] | max // 0' 2>/dev/null)

  # Check thresholds
  status="OK"
  reasons=""

  if (( error_total > ERROR_THRESHOLD )); then
    status="ALERT"
    reasons="$reasons Errors=$error_total"
  fi
  if (( throttle_total > THROTTLE_THRESHOLD )); then
    status="ALERT"
    reasons="$reasons Throttles=$throttle_total"
  fi
  if (( duration_max > DURATION_P99_THRESHOLD )); then
    status="ALERT"
    reasons="$reasons DurationMax=${duration_max}ms"
  fi

  if [[ "$status" == "ALERT" ]]; then
    echo "ALERT: $name (runtime=$runtime) -$reasons"
    alerts+=("$name|$runtime|$error_total|$throttle_total|$duration_max|$reasons")
  else
    echo "OK: $name (runtime=$runtime) errors=$error_total throttles=$throttle_total duration_max=${duration_max}ms"
  fi
done

if [[ ${#alerts[@]} -gt 0 ]]; then
  echo ""
  echo "Total alerts: ${#alerts[@]}"
  if [[ "$DRY_RUN" == false ]]; then
    echo "Would send alerts to SNS topic or email (not yet implemented)"
  fi
fi

echo "Done."
