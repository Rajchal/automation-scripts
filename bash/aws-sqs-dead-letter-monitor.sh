#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-sqs-dead-letter-monitor.log"
REPORT_FILE="/tmp/sqs-dlq-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
DLQ_COUNT_THRESHOLD="${SQS_DLQ_COUNT_THRESHOLD:-10}"
DLQ_AGE_THRESHOLD_SECONDS="${SQS_DLQ_AGE_THRESHOLD_SECONDS:-3600}"
MAX_QUEUES="${SQS_MAX_QUEUES:-100}"
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
  echo "SQS DLQ Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "DLQ count threshold: $DLQ_COUNT_THRESHOLD" >> "$REPORT_FILE"
  echo "DLQ age threshold (s): $DLQ_AGE_THRESHOLD_SECONDS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  queues_json=$(aws sqs list-queues --max-results "$MAX_QUEUES" --region "$REGION" --output json 2>/dev/null || echo '{"QueueUrls":[]}')
  queues=$(echo "$queues_json" | jq -r '.QueueUrls[]?')

  if [ -z "$queues" ]; then
    echo "No SQS queues found." >> "$REPORT_FILE"
    log_message "No SQS queues in region $REGION"
    exit 0
  fi

  total=0
  alerts=0

  for q in $queues; do
    total=$((total+1))
    attrs=$(aws sqs get-queue-attributes --queue-url "$q" --attribute-names RedrivePolicy --region "$REGION" --output json 2>/dev/null || echo '{}')
    redrive=$(echo "$attrs" | jq -r '.Attributes.RedrivePolicy // empty')
    if [ -z "$redrive" ]; then
      continue
    fi

    dlq_arn=$(echo "$redrive" | jq -r '.deadLetterTargetArn // empty')
    if [ -z "$dlq_arn" ]; then
      continue
    fi

    # Convert DLQ ARN to URL (assume same account/region pattern) — use list-queues and match by name
    dlq_name=$(echo "$dlq_arn" | awk -F: '{print $NF}')
    dlq_url=$(aws sqs list-queues --queue-name-prefix "$dlq_name" --region "$REGION" --output json 2>/dev/null | jq -r '.QueueUrls[]? | select(contains("'"$dlq_name"'"))' 2>/dev/null || true)
    if [ -z "$dlq_url" ]; then
      # fallback: try standard URL construction
      account_id=$(echo "$dlq_arn" | awk -F: '{print $5}')
      dlq_url="https://sqs.$REGION.amazonaws.com/$account_id/$dlq_name"
    fi

    # Get approximate number of messages in DLQ
    dlq_attrs=$(aws sqs get-queue-attributes --queue-url "$dlq_url" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible --region "$REGION" --output json 2>/dev/null || echo '{}')
    dlq_count=$(echo "$dlq_attrs" | jq -r '.Attributes.ApproximateNumberOfMessages // 0')

    # Check age of oldest message via CloudWatch ApproximateAgeOfOldestMessage
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    start_time=$(date -u -d "5 minutes ago" +%Y-%m-%dT%H:%M:%SZ)
    cw=$(aws cloudwatch get-metric-statistics --namespace AWS/SQS --metric-name ApproximateAgeOfOldestMessage --dimensions Name=QueueName,Value="$dlq_name" --start-time "$start_time" --end-time "$now" --period 300 --statistics Maximum --region "$REGION" --output json 2>/dev/null || echo '{"Datapoints":[]}')
    age=$(echo "$cw" | jq -r '[.Datapoints[].Maximum] | max // 0')

    echo "Queue: $q" >> "$REPORT_FILE"
    echo "DLQ: $dlq_name ($dlq_url)" >> "$REPORT_FILE"
    echo "DLQ count: $dlq_count" >> "$REPORT_FILE"
    echo "DLQ oldest message age (s): $age" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    if [ "$dlq_count" -ge "$DLQ_COUNT_THRESHOLD" ] || [ "$(printf '%s' "$age" | awk '{print int($1)}')" -ge "$DLQ_AGE_THRESHOLD_SECONDS" ]; then
      send_slack_alert "SQS DLQ Alert: Queue $q has DLQ $dlq_name with $dlq_count messages, oldest age ${age}s"
      alerts=$((alerts+1))
    fi
  done

  echo "Summary: total_queues=$total, alerts=$alerts" >> "$REPORT_FILE"
  log_message "SQS DLQ report written to $REPORT_FILE (total_queues=$total, alerts=$alerts)"
}

main "$@"
