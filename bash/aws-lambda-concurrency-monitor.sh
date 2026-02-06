#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-lambda-concurrency-monitor.log"
REPORT_FILE="/tmp/lambda-concurrency-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MAX_FUNCTIONS="${LAMBDA_MAX_FUNCTIONS:-200}"
LOOKBACK_MINUTES="${LAMBDA_LOOKBACK_MINUTES:-5}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "Lambda Concurrency Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Lookback minutes: $LOOKBACK_MINUTES" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

metric_sum() {
  # namespace metric dimName dimValue start end period
  aws cloudwatch get-metric-statistics --namespace "$1" --metric-name "$2" --dimensions Name=$3,Value="$4" --start-time "$5" --end-time "$6" --period $7 --statistics Sum --region "$REGION" --output json 2>/dev/null | jq -r '[.Datapoints[].Sum] | add // 0'
}

main() {
  write_header

  funcs_json=$(aws lambda list-functions --max-items "$MAX_FUNCTIONS" --region "$REGION" --output json 2>/dev/null || echo '{"Functions":[]}')
  functions=$(echo "$funcs_json" | jq -r '.Functions[]?.FunctionName')

  if [ -z "$functions" ]; then
    echo "No Lambda functions found." >> "$REPORT_FILE"
    log_message "No Lambda functions in region $REGION"
    exit 0
  fi

  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  start_time=$(date -u -d "${LOOKBACK_MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ)

  total=0
  alerts=0

  for fn in $functions; do
    total=$((total+1))
    cfg=$(aws lambda get-function-configuration --function-name "$fn" --region "$REGION" --output json 2>/dev/null || echo '{}')
    reserved=$(echo "$cfg" | jq -r '.ReservedConcurrentExecutions // "unreserved"')
    runtime=$(echo "$cfg" | jq -r '.Runtime // "<unknown>"')

    # Check CloudWatch metrics for Throttles and Errors
    throttles=$(metric_sum "AWS/Lambda" "Throttles" "FunctionName" "$fn" "$start_time" "$now" 60 || echo 0)
    errors=$(metric_sum "AWS/Lambda" "Errors" "FunctionName" "$fn" "$start_time" "$now" 60 || echo 0)

    echo "Function: $fn" >> "$REPORT_FILE"
    echo "  Runtime: $runtime" >> "$REPORT_FILE"
    echo "  ReservedConcurrentExecutions: $reserved" >> "$REPORT_FILE"
    echo "  Throttles (last ${LOOKBACK_MINUTES}m sum): $throttles" >> "$REPORT_FILE"
    echo "  Errors (last ${LOOKBACK_MINUTES}m sum): $errors" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    if [ "$(printf '%s' "$throttles" | awk '{print int($1)}')" -gt 0 ]; then
      send_slack_alert "Lambda Alert: Function $fn has $throttles throttles in the last ${LOOKBACK_MINUTES}m"
      alerts=$((alerts+1))
    fi

    if [ "$(printf '%s' "$errors" | awk '{print int($1)}')" -gt 0 ]; then
      send_slack_alert "Lambda Alert: Function $fn has $errors errors in the last ${LOOKBACK_MINUTES}m"
      alerts=$((alerts+1))
    fi
  done

  echo "Summary: total_functions=$total, alerts=$alerts" >> "$REPORT_FILE"
  log_message "Lambda concurrency report written to $REPORT_FILE (total=$total, alerts=$alerts)"
}

main "$@"
