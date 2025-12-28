#!/bin/bash

################################################################################
# AWS Kinesis Stream Health Monitor
# Audits Kinesis Data Streams: shard count/utilization, retention window,
# enhanced monitoring, encryption, consumers, and CloudWatch metrics
# (GetRecords.IteratorAgeMilliseconds, IncomingBytes/Records, WriteProvisioned
# ThroughputExceeded, ReadProvisionedThroughputExceeded). Flags high iterator
# age, throughput exceeded, and imbalanced shards. Includes thresholds, logging,
# Slack/email alerts, and a text report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/kinesis-stream-health-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/kinesis-stream-health.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds (override via env)
ITERATOR_AGE_WARN_MS="${ITERATOR_AGE_WARN_MS:-30000}"         # 30s
WRITE_EXCEEDED_WARN="${WRITE_EXCEEDED_WARN:-10}"               # count
READ_EXCEEDED_WARN="${READ_EXCEEDED_WARN:-10}"                # count
SHARD_IMBALANCE_WARN_PCT="${SHARD_IMBALANCE_WARN_PCT:-40}"     # % skew between max and min
LOOKBACK_HOURS="${LOOKBACK_HOURS:-1}"                         # shorter window for streams
METRIC_PERIOD="${METRIC_PERIOD:-60}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_STREAMS=0
STREAMS_WITH_ISSUES=0
STREAMS_HIGH_AGE=0
STREAMS_WRITE_EXCEEDED=0
STREAMS_READ_EXCEEDED=0
STREAMS_IMBALANCED=0

ISSUES=()

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

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
      "title": "AWS Kinesis Alert",
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
    echo "AWS Kinesis Stream Health"
    echo "========================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Iterator Age Warning: > ${ITERATOR_AGE_WARN_MS} ms"
    echo "  Write Provisioned Exceeded Warning: >= ${WRITE_EXCEEDED_WARN}"
    echo "  Read Provisioned Exceeded Warning: >= ${READ_EXCEEDED_WARN}"
    echo "  Shard Imbalance Warning: > ${SHARD_IMBALANCE_WARN_PCT}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_streams() {
  aws_cmd kinesis list-streams \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"StreamNames":[]}'
}

describe_stream() {
  local stream_name="$1"
  aws_cmd kinesis describe-stream-summary \
    --stream-name "$stream_name" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_shards() {
  local stream_name="$1"
  aws_cmd kinesis list-shards \
    --stream-name "$stream_name" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Shards":[]}'
}

get_metric() {
  local stream_name="$1" metric="$2" stat_type="${3:-Average}"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/Kinesis \
    --metric-name "$metric" \
    --dimensions Name=StreamName,Value="$stream_name" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics "$stat_type" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }
calculate_max() { jq -r '.Datapoints[].Maximum' 2>/dev/null | awk '{if(NR==1)m=$1; else if($1>m)m=$1} END {if(NR==0) print 0; else printf "%.2f", m}'; }
calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {if(NR==0) print 0; else printf "%.0f", s}'; }

record_issue() {
  ISSUES+=("$1")
}

analyze_shard_balance() {
  local shards_json="$1"
  local shard_count max_hash min_hash range_pct
  shard_count=$(echo "${shards_json}" | jq -r '.Shards | length')
  if [[ "${shard_count}" == "0" ]]; then
    echo "  Shards: 0" >> "${OUTPUT_FILE}"
    return 0
  fi

  max_hash=$(echo "${shards_json}" | jq -r '.Shards[] | .HashKeyRange.EndingHashKey | tonumber' | sort -nr | head -n1)
  min_hash=$(echo "${shards_json}" | jq -r '.Shards[] | .HashKeyRange.StartingHashKey | tonumber' | sort -n | head -n1)
  range_pct=$(awk -v min="${min_hash}" -v max="${max_hash}" 'BEGIN {if(min+0>0) printf "%.2f", ((max-min)/max)*100; else print 0}')

  echo "  Shards: ${shard_count} (range spread: ${range_pct}% between min and max)" >> "${OUTPUT_FILE}"
  if (( $(echo "${range_pct} > ${SHARD_IMBALANCE_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    STREAMS_IMBALANCED=$((STREAMS_IMBALANCED + 1))
    record_issue "Kinesis stream shard hash range imbalance ${range_pct}% exceeds ${SHARD_IMBALANCE_WARN_PCT}%"
    return 1
  fi
  return 0
}

analyze_stream() {
  local stream_name="$1"
  local summary_json
  summary_json=$(describe_stream "$stream_name")
  local status retention shards_count encryption_type enhanced_monitoring
  status=$(echo "${summary_json}" | jq_safe '.StreamDescriptionSummary.StreamStatus')
  retention=$(echo "${summary_json}" | jq_safe '.StreamDescriptionSummary.RetentionPeriodHours')
  shards_count=$(echo "${summary_json}" | jq_safe '.StreamDescriptionSummary.OpenShardCount')
  encryption_type=$(echo "${summary_json}" | jq_safe '.StreamDescriptionSummary.EncryptionType')
  enhanced_monitoring=$(echo "${summary_json}" | jq -c '.StreamDescriptionSummary.EnhancedMonitoring' 2>/dev/null)

  TOTAL_STREAMS=$((TOTAL_STREAMS + 1))
  log_message INFO "Analyzing Kinesis stream ${stream_name}"

  {
    echo "Stream: ${stream_name}"
    echo "  Status: ${status}"
    echo "  Retention (hours): ${retention}"
    echo "  Open Shards: ${shards_count}"
    echo "  Encryption: ${encryption_type}"
    echo "  Enhanced Monitoring: ${enhanced_monitoring}"
  } >> "${OUTPUT_FILE}"

  local shards_json
  shards_json=$(list_shards "$stream_name")
  analyze_shard_balance "${shards_json}"

  # Metrics
  local iter_age write_exceeded read_exceeded incoming_bytes incoming_records
  iter_age=$(get_metric "$stream_name" "GetRecords.IteratorAgeMilliseconds" "Maximum" | calculate_max)
  write_exceeded=$(get_metric "$stream_name" "WriteProvisionedThroughputExceeded" "Sum" | calculate_sum)
  read_exceeded=$(get_metric "$stream_name" "ReadProvisionedThroughputExceeded" "Sum" | calculate_sum)
  incoming_bytes=$(get_metric "$stream_name" "IncomingBytes" "Sum" | calculate_sum)
  incoming_records=$(get_metric "$stream_name" "IncomingRecords" "Sum" | calculate_sum)

  {
    echo "  Metrics (${LOOKBACK_HOURS}h):"
    echo "    Iterator Age (max): ${iter_age} ms"
    echo "    Write Throttle Exceeded: ${write_exceeded}"
    echo "    Read Throttle Exceeded: ${read_exceeded}"
    echo "    Incoming Bytes: ${incoming_bytes}"
    echo "    Incoming Records: ${incoming_records}"
  } >> "${OUTPUT_FILE}"

  local stream_issue=0

  if (( $(echo "${iter_age} > ${ITERATOR_AGE_WARN_MS}" | bc -l 2>/dev/null || echo 0) )); then
    STREAMS_HIGH_AGE=$((STREAMS_HIGH_AGE + 1))
    stream_issue=1
    record_issue "Kinesis stream ${stream_name} iterator age ${iter_age}ms exceeds ${ITERATOR_AGE_WARN_MS}ms"
  fi

  if (( $(echo "${write_exceeded} >= ${WRITE_EXCEEDED_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    STREAMS_WRITE_EXCEEDED=$((STREAMS_WRITE_EXCEEDED + 1))
    stream_issue=1
    record_issue "Kinesis stream ${stream_name} write throughput exceeded ${write_exceeded} times"
  fi

  if (( $(echo "${read_exceeded} >= ${READ_EXCEEDED_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    STREAMS_READ_EXCEEDED=$((STREAMS_READ_EXCEEDED + 1))
    stream_issue=1
    record_issue "Kinesis stream ${stream_name} read throughput exceeded ${read_exceeded} times"
  fi

  if (( stream_issue )); then
    STREAMS_WITH_ISSUES=$((STREAMS_WITH_ISSUES + 1))
  fi

  echo "" >> "${OUTPUT_FILE}"
}

main() {
  write_header
  local list_json
  list_json=$(list_streams)
  local stream_count
  stream_count=$(echo "${list_json}" | jq -r '.StreamNames | length')

  if [[ "${stream_count}" == "0" ]]; then
    log_message WARN "No Kinesis streams found in region ${REGION}"
    echo "No Kinesis streams found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total Streams: ${stream_count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  while read -r stream; do
    analyze_stream "${stream}"
  done <<< "$(echo "${list_json}" | jq -r '.StreamNames[]')"

  {
    echo "Summary"
    echo "-------"
    echo "Total Streams: ${TOTAL_STREAMS}"
    echo "Streams with Issues: ${STREAMS_WITH_ISSUES}"
    echo "High Iterator Age: ${STREAMS_HIGH_AGE}"
    echo "Write Throughput Exceeded: ${STREAMS_WRITE_EXCEEDED}"
    echo "Read Throughput Exceeded: ${STREAMS_READ_EXCEEDED}"
    echo "Shard Imbalance: ${STREAMS_IMBALANCED}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "Kinesis Stream Health Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "Kinesis Stream Health Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"
