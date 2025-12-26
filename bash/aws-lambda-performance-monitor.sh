#!/bin/bash

################################################################################
# AWS Lambda Performance Monitor
# Audits Lambda functions: lists functions, checks concurrency/reserved
# settings, memory/timeout, VPC config, DLQ, env vars encryption, last modified,
# and pulls CloudWatch metrics (AWS/Lambda Invocations, Errors, Throttles,
# Duration p95/p99 and Average, IteratorAge for streams). Includes env
# thresholds, logging, Slack/email alerts, and a text report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/lambda-performance-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/lambda-performance-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds (override via env)
ERROR_RATE_WARN_PCT="${ERROR_RATE_WARN_PCT:-2}"      # % Errors vs Invocations
THROTTLE_WARN="${THROTTLE_WARN:-1}"                 # Throttles count
DURATION_P95_WARN_MS="${DURATION_P95_WARN_MS:-1000}" # p95 duration in ms
ITERATOR_AGE_WARN_MS="${ITERATOR_AGE_WARN_MS:-30000}" # IteratorAge in ms
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_FUNCTIONS=0
FUNCS_IN_VPC=0
FUNCS_WITH_DLH=0
FUNCS_WITH_KMS=0
FUNCS_WITH_ISSUES=0
FUNCS_HIGH_ERROR=0
FUNCS_THROTTLED=0
FUNCS_HIGH_DURATION=0
FUNCS_HIGH_ITER_AGE=0

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

# Helpers
jq_safe() { jq -r "$1" 2>/dev/null || echo ""; }

aws_cmd() {
  if [[ -n "${PROFILE}" ]]; then AWS_PROFILE="${PROFILE}" aws "$@"; else aws "$@"; fi
}

send_slack_alert() {
  local message="$1"
  local severity="${2:-INFO}"
  [[ -z "${SLACK_WEBHOOK}" ]] && return
  local color
  case "${severity}" in
    CRITICAL) color="danger" ;;
    WARNING)  color="warning" ;;
    INFO)     color="good" ;;
    *)        color="good" ;;
  esac
  local payload
  payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "${color}",
      "title": "AWS Lambda Alert",
      "text": "${message}",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || true
}

send_email_alert() {
  local subject="$1"
  local body="$2"
  [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null && return
  echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true
}

write_header() {
  {
    echo "AWS Lambda Performance Monitor"
    echo "=============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Error Rate Warning: > ${ERROR_RATE_WARN_PCT}%"
    echo "  Throttles Warning: >= ${THROTTLE_WARN}"
    echo "  Duration p95 Warning: > ${DURATION_P95_WARN_MS}ms"
    echo "  IteratorAge Warning: > ${ITERATOR_AGE_WARN_MS}ms"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_functions() {
  aws_cmd lambda list-functions \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Functions":[]}'
}

get_concurrency() {
  local func="$1"
  aws_cmd lambda get-function-concurrency \
    --function-name "$func" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_metrics() {
  local func="$1" metric="$2" stat_type="$3"
  local extra_stats=( )
  if [[ "$stat_type" == "EXTENDED" ]]; then
    extra_stats+=(--extended-statistics p95 p99)
  else
    extra_stats+=(--statistics Sum Average)
  fi
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name "$metric" \
    --dimensions Name=FunctionName,Value="$func" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    "${extra_stats[@]}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s}'; }
calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }
calculate_p() { local p="$1"; jq -r ".Datapoints[].ExtendedStatistics.p${p}" 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }

write_function_header() {
  local name="$1" runtime="$2" last_modified="$3"
  {
    echo "Function: ${name}"
    echo "  Runtime: ${runtime}"
    echo "  Last Modified: ${last_modified}"
  } >> "${OUTPUT_FILE}"
}

analyze_function() {
  local func_json="$1"
  local name runtime memory timeout last_modified vpc_config dlq kms_key handler
  name=$(echo "$func_json" | jq_safe '.FunctionName')
  runtime=$(echo "$func_json" | jq_safe '.Runtime')
  memory=$(echo "$func_json" | jq_safe '.MemorySize')
  timeout=$(echo "$func_json" | jq_safe '.Timeout')
  last_modified=$(echo "$func_json" | jq_safe '.LastModified')
  vpc_config=$(echo "$func_json" | jq_safe '.VpcConfig.SubnetIds | length')
  dlq=$(echo "$func_json" | jq_safe '.DeadLetterConfig.TargetArn // ""')
  kms_key=$(echo "$func_json" | jq_safe '.KMSKeyArn // ""')
  handler=$(echo "$func_json" | jq_safe '.Handler')

  TOTAL_FUNCTIONS=$((TOTAL_FUNCTIONS + 1))
  [[ "$vpc_config" != "0" ]] && ((FUNCS_IN_VPC++))
  [[ -n "$dlq" && "$dlq" != "null" ]] && ((FUNCS_WITH_DLH++))
  [[ -n "$kms_key" && "$kms_key" != "null" ]] && ((FUNCS_WITH_KMS++))

  write_function_header "$name" "$runtime" "$last_modified"
  {
    echo "  Handler: ${handler}"
    echo "  Memory: ${memory} MB"
    echo "  Timeout: ${timeout} sec"
    echo "  VPC Attached: $([[ "$vpc_config" != "0" ]] && echo yes || echo no)"
    echo "  DLQ: $([[ -n "$dlq" && "$dlq" != "null" ]] && echo "$dlq" || echo none)"
    echo "  KMS Env Encryption: $([[ -n "$kms_key" && "$kms_key" != "null" ]] && echo yes || echo no)"
  } >> "${OUTPUT_FILE}"

  # Concurrency
  local conc_json reserved
  conc_json=$(get_concurrency "$name")
  reserved=$(echo "$conc_json" | jq_safe '.ReservedConcurrentExecutions // "unreserved"')
  echo "  Reserved Concurrency: ${reserved}" >> "${OUTPUT_FILE}"

  # Metrics
  analyze_metrics "$name"

  echo "" >> "${OUTPUT_FILE}"
}

analyze_metrics() {
  local func_name="$1"
  echo "  Metrics (${LOOKBACK_HOURS}h):" >> "${OUTPUT_FILE}"

  local inv_json err_json thr_json dur_json iter_json
  inv_json=$(get_metrics "$func_name" "Invocations" "BASIC")
  err_json=$(get_metrics "$func_name" "Errors" "BASIC")
  thr_json=$(get_metrics "$func_name" "Throttles" "BASIC")
  dur_json=$(get_metrics "$func_name" "Duration" "EXTENDED")
  iter_json=$(get_metrics "$func_name" "IteratorAge" "BASIC")

  local inv_sum err_sum thr_sum dur_avg dur_p95 dur_p99 iter_p95
  inv_sum=$(echo "$inv_json" | calculate_sum)
  err_sum=$(echo "$err_json" | calculate_sum)
  thr_sum=$(echo "$thr_json" | calculate_sum)
  dur_avg=$(echo "$dur_json" | calculate_avg)
  dur_p95=$(echo "$dur_json" | calculate_p 95)
  dur_p99=$(echo "$dur_json" | calculate_p 99)
  iter_p95=$(echo "$iter_json" | calculate_p 95)

  echo "    Invocations: ${inv_sum}" >> "${OUTPUT_FILE}"
  echo "    Errors: ${err_sum}" >> "${OUTPUT_FILE}"
  echo "    Throttles: ${thr_sum}" >> "${OUTPUT_FILE}"
  echo "    Duration Avg: ${dur_avg} ms" >> "${OUTPUT_FILE}"
  echo "    Duration p95: ${dur_p95} ms" >> "${OUTPUT_FILE}"
  echo "    Duration p99: ${dur_p99} ms" >> "${OUTPUT_FILE}"
  echo "    IteratorAge p95: ${iter_p95} ms" >> "${OUTPUT_FILE}"

  # Error rate
  local error_rate="0"
  if [[ ${inv_sum} -gt 0 ]]; then
    error_rate=$(echo "scale=2; ${err_sum} * 100 / ${inv_sum}" | bc -l 2>/dev/null || echo "0")
  fi
  echo "    Error Rate: ${error_rate}%" >> "${OUTPUT_FILE}"

  # Threshold checks
  if (( $(echo "${error_rate} > ${ERROR_RATE_WARN_PCT}" | bc -l) )); then
    ((FUNCS_HIGH_ERROR++))
    ((FUNCS_WITH_ISSUES++))
    printf "    %b⚠️  High error rate%b\n" "${RED}" "${NC}" >> "${OUTPUT_FILE}"
  fi
  if (( $(echo "${thr_sum} >= ${THROTTLE_WARN}" | bc -l) )); then
    ((FUNCS_THROTTLED++))
    ((FUNCS_WITH_ISSUES++))
    printf "    %b⚠️  Throttling detected%b\n" "${YELLOW}" "${NC}" >> "${OUTPUT_FILE}"
  fi
  if (( $(echo "${dur_p95} > ${DURATION_P95_WARN_MS}" | bc -l) )); then
    ((FUNCS_HIGH_DURATION++))
    ((FUNCS_WITH_ISSUES++))
    printf "    %b⚠️  High duration p95%b\n" "${YELLOW}" "${NC}" >> "${OUTPUT_FILE}"
  fi
  if (( $(echo "${iter_p95} > ${ITERATOR_AGE_WARN_MS}" | bc -l) )); then
    ((FUNCS_HIGH_ITER_AGE++))
    ((FUNCS_WITH_ISSUES++))
    printf "    %b⚠️  High iterator age%b\n" "${YELLOW}" "${NC}" >> "${OUTPUT_FILE}"
  fi
}

summary_section() {
  {
    echo "=== LAMBDA SUMMARY ==="
    echo ""
    printf "Total Functions: %d\n" "${TOTAL_FUNCTIONS}"
    printf "Functions in VPC: %d\n" "${FUNCS_IN_VPC}"
    printf "Functions with DLQ: %d\n" "${FUNCS_WITH_DLH}"
    printf "Functions with KMS Env: %d\n" "${FUNCS_WITH_KMS}"
    echo ""
    printf "High Error Rate: %d\n" "${FUNCS_HIGH_ERROR}"
    printf "Throttled: %d\n" "${FUNCS_THROTTLED}"
    printf "High Duration: %d\n" "${FUNCS_HIGH_DURATION}"
    printf "High Iterator Age: %d\n" "${FUNCS_HIGH_ITER_AGE}"
    printf "Functions with Issues: %d\n" "${FUNCS_WITH_ISSUES}"
    echo ""
    if [[ ${FUNCS_HIGH_ERROR} -gt 0 ]] || [[ ${FUNCS_THROTTLED} -gt 0 ]]; then
      printf "%b[CRITICAL] Errors or throttles detected%b\n" "${RED}" "${NC}"
    elif [[ ${FUNCS_HIGH_DURATION} -gt 0 ]] || [[ ${FUNCS_HIGH_ITER_AGE} -gt 0 ]]; then
      printf "%b[WARNING] Latency or iterator age concerns%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] Lambda fleet looks healthy%b\n" "${GREEN}" "${NC}"
    fi
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations_section() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    if [[ ${FUNCS_HIGH_ERROR} -gt 0 ]]; then
      echo "Reduce Errors:"
      echo "  • Check recent deployments and roll back if needed"
      echo "  • Inspect CloudWatch logs for stack traces"
      echo "  • Validate input payloads and retries"
      echo "  • Add DLQ for async invocations"
      echo "  • Implement idempotency and circuit breakers"
      echo ""
    fi
    if [[ ${FUNCS_THROTTLED} -gt 0 ]]; then
      echo "Address Throttling:"
      echo "  • Increase reserved concurrency for critical functions"
      echo "  • Use provisioned concurrency for cold-start sensitive paths"
      echo "  • Implement backoff/retry and queues (SQS/Kinesis)"
      echo "  • Split workloads by alias with per-alias concurrency"
      echo ""
    fi
    if [[ ${FUNCS_HIGH_DURATION} -gt 0 ]]; then
      echo "Reduce Duration:"
      echo "  • Right-size memory (more memory = more CPU)"
      echo "  • Reuse SDK clients and connections"
      echo "  • Avoid large cold-start init; pre-initialize common deps"
      echo "  • Consider provisioned concurrency"
      echo "  • Profile hotspots and optimize I/O"
      echo ""
    fi
    if [[ ${FUNCS_HIGH_ITER_AGE} -gt 0 ]]; then
      echo "Lower Iterator Age:"
      echo "  • Increase batch size or parallelization"
      echo "  • Reduce function duration to keep up with stream"
      echo "  • Scale consumer count (Kinesis enhanced fan-out)"
      echo "  • Review DLQ handling for batch failures"
      echo ""
    fi
    echo "Security & Config:"
    echo "  • Ensure KMS encryption for env vars where needed"
    echo "  • Attach least-privilege IAM roles"
    echo "  • Use VPC only when required; keep subnets routable"
    echo "  • Set DLQ/SNS/SQS for async error handling"
    echo "  • Keep timeouts aligned with upstream SLAs"
    echo ""
    echo "Observability:"
    echo "  • CloudWatch alarms on Errors, Throttles, Duration"
    echo "  • Enable X-Ray for tracing"
    echo "  • Use structured logging with request IDs"
    echo "  • Enable Lambda insights where applicable"
    echo ""
    echo "Cost Optimization:"
    echo "  • Right-size memory and execution time"
    echo "  • Use ARM/Graviton where possible"
    echo "  • Consolidate functions with similar code paths"
    echo "  • Remove unused versions/aliases"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Lambda Performance Monitor Started ==="
  write_header

  local funcs_json
  funcs_json=$(list_functions)
  local funcs
  funcs=$(echo "$funcs_json" | jq -c '.Functions[]?' 2>/dev/null)

  if [[ -z "$funcs" ]]; then
    echo "No Lambda functions found." >> "${OUTPUT_FILE}"
  else
    while IFS= read -r fn; do
      [[ -z "$fn" ]] && continue
      analyze_function "$fn"
    done <<< "$funcs"
  fi

  summary_section
  recommendations_section
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS Lambda Documentation: https://docs.aws.amazon.com/lambda/latest/dg/"
  } >> "${OUTPUT_FILE}"
  cat "${OUTPUT_FILE}"
  log_message INFO "=== Lambda Performance Monitor Completed ==="

  # Alerts
  if [[ ${FUNCS_HIGH_ERROR} -gt 0 ]] || [[ ${FUNCS_THROTTLED} -gt 0 ]]; then
    send_slack_alert "🚨 Lambda errors/throttles: errors=${FUNCS_HIGH_ERROR}, throttled=${FUNCS_THROTTLED}" "CRITICAL"
    send_email_alert "Lambda Critical Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${FUNCS_HIGH_DURATION} -gt 0 ]] || [[ ${FUNCS_HIGH_ITER_AGE} -gt 0 ]]; then
    send_slack_alert "⚠️ Lambda latency/iterator issues: duration=${FUNCS_HIGH_DURATION}, iterator=${FUNCS_HIGH_ITER_AGE}" "WARNING"
  fi
}

main "$@"
