#!/bin/bash

################################################################################
# AWS SNS/SQS Message Flow Monitor
# Monitors SNS topics and SQS queues, tracks message flow, detects dead letter
# queues, analyzes processing delays, and provides optimization recommendations.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/sns-sqs-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/sns-sqs-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
DLQ_MESSAGE_WARN="${DLQ_MESSAGE_WARN:-10}"           # messages in DLQ
AGE_OF_OLDEST_WARN="${AGE_OF_OLDEST_WARN:-3600}"     # seconds
QUEUE_DEPTH_WARN="${QUEUE_DEPTH_WARN:-1000}"         # messages
MESSAGE_DELAY_WARN="${MESSAGE_DELAY_WARN:-300}"      # seconds
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_TOPICS=0
TOTAL_QUEUES=0
QUEUES_WITH_DLQ=0
QUEUES_WITH_BACKLOG=0
QUEUES_WITH_OLD_MESSAGES=0

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
      "title": "SNS/SQS Message Flow Alert",
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
    echo "AWS SNS/SQS Message Flow Monitor"
    echo "================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  DLQ Messages Warning: ${DLQ_MESSAGE_WARN}"
    echo "  Oldest Message Warning: ${AGE_OF_OLDEST_WARN}s"
    echo "  Queue Depth Warning: ${QUEUE_DEPTH_WARN}"
    echo "  Message Delay Warning: ${MESSAGE_DELAY_WARN}s"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_topics() {
  aws sns list-topics \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Topics":[]}'
}

get_topic_attributes() {
  local topic_arn="$1"
  aws sns get-topic-attributes \
    --topic-arn "${topic_arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Attributes":{}}'
}

list_subscriptions_by_topic() {
  local topic_arn="$1"
  aws sns list-subscriptions-by-topic \
    --topic-arn "${topic_arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Subscriptions":[]}'
}

list_queues() {
  aws sqs list-queues \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"QueueUrls":[]}'
}

get_queue_attributes() {
  local queue_url="$1"
  aws sqs get-queue-attributes \
    --queue-url "${queue_url}" \
    --attribute-names All \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Attributes":{}}'
}

get_sns_metrics() {
  local topic_name="$1"
  local metric_name="$2"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/SNS \
    --metric-name "${metric_name}" \
    --dimensions Name=TopicName,Value="${topic_name}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Sum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

get_sqs_metrics() {
  local queue_name="$1"
  local metric_name="$2"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/SQS \
    --metric-name "${metric_name}" \
    --dimensions Name=QueueName,Value="${queue_name}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Sum,Average \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() {
  jq -r '.Datapoints[].Sum' 2>/dev/null | \
    awk '{s+=$1} END {printf "%.0f", s}'
}

calculate_avg() {
  jq -r '.Datapoints[].Average' 2>/dev/null | \
    awk '{s+=$1; c++} END {if (c>0) printf "%.2f", s/c; else print "0"}'
}

monitor_sns_topics() {
  log_message INFO "Monitoring SNS topics"
  
  {
    echo "=== SNS TOPICS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local topics_json
  topics_json=$(list_topics)
  
  local topic_count
  topic_count=$(echo "${topics_json}" | jq '.Topics | length' 2>/dev/null || echo "0")
  
  TOTAL_TOPICS=${topic_count}
  
  if [[ ${topic_count} -eq 0 ]]; then
    {
      echo "No SNS topics found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total Topics: ${topic_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local topics
  topics=$(echo "${topics_json}" | jq -r '.Topics[].TopicArn' 2>/dev/null)
  
  while IFS= read -r topic_arn; do
    [[ -z "${topic_arn}" ]] && continue
    
    local topic_name
    topic_name=$(echo "${topic_arn}" | awk -F: '{print $NF}')
    
    log_message INFO "Analyzing SNS topic: ${topic_name}"
    
    {
      echo "Topic: ${topic_name}"
      echo "ARN: ${topic_arn}"
    } >> "${OUTPUT_FILE}"
    
    # Get topic attributes
    local attrs_json
    attrs_json=$(get_topic_attributes "${topic_arn}")
    
    local display_name policy
    display_name=$(echo "${attrs_json}" | jq_safe '.Attributes.DisplayName // "N/A"')
    policy=$(echo "${attrs_json}" | jq_safe '.Attributes.Policy // "N/A"' | wc -c)
    
    {
      echo "Display Name: ${display_name}"
    } >> "${OUTPUT_FILE}"
    
    # Get subscriptions
    local subs_json
    subs_json=$(list_subscriptions_by_topic "${topic_arn}")
    
    local sub_count
    sub_count=$(echo "${subs_json}" | jq '.Subscriptions | length' 2>/dev/null || echo "0")
    
    {
      echo "Subscriptions: ${sub_count}"
    } >> "${OUTPUT_FILE}"
    
    if [[ ${sub_count} -gt 0 ]]; then
      local subs
      subs=$(echo "${subs_json}" | jq -c '.Subscriptions[]' 2>/dev/null)
      
      while IFS= read -r sub; do
        [[ -z "${sub}" ]] && continue
        
        local protocol endpoint status
        protocol=$(echo "${sub}" | jq_safe '.Protocol')
        endpoint=$(echo "${sub}" | jq_safe '.Endpoint' | head -c 50)
        status=$(echo "${sub}" | jq_safe '.SubscriptionArn')
        
        if [[ "${status}" == "PendingConfirmation" ]]; then
          {
            printf "  - %s: %s... %b(Pending)%b\n" "${protocol}" "${endpoint}" "${YELLOW}" "${NC}"
          } >> "${OUTPUT_FILE}"
        else
          {
            echo "  - ${protocol}: ${endpoint}..."
          } >> "${OUTPUT_FILE}"
        fi
      done <<< "${subs}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Get metrics
    analyze_topic_metrics "${topic_name}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${topics}"
}

analyze_topic_metrics() {
  local topic_name="$1"
  
  {
    echo "Metrics (${LOOKBACK_HOURS}h):"
  } >> "${OUTPUT_FILE}"
  
  # Get message metrics
  local published_json delivered_json failed_json
  published_json=$(get_sns_metrics "${topic_name}" "NumberOfMessagesPublished")
  delivered_json=$(get_sns_metrics "${topic_name}" "NumberOfNotificationsDelivered")
  failed_json=$(get_sns_metrics "${topic_name}" "NumberOfNotificationsFailed")
  
  local published_count delivered_count failed_count
  published_count=$(echo "${published_json}" | calculate_sum)
  delivered_count=$(echo "${delivered_json}" | calculate_sum)
  failed_count=$(echo "${failed_json}" | calculate_sum)
  
  {
    echo "  Messages Published: ${published_count}"
    echo "  Notifications Delivered: ${delivered_count}"
    echo "  Notifications Failed: ${failed_count}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${published_count} -gt 0 ]] && [[ ${failed_count} -gt 0 ]]; then
    local failure_rate
    failure_rate=$(echo "scale=2; ${failed_count} * 100 / ${published_count}" | bc -l)
    
    {
      echo "  Failure Rate: ${failure_rate}%"
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${failure_rate} > 1" | bc -l) )); then
      {
        printf "  %b⚠️  High notification failure rate%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "SNS topic ${topic_name} has high failure rate: ${failure_rate}%"
    fi
  elif [[ ${published_count} -gt 0 ]]; then
    {
      printf "  %b✓ All notifications delivered successfully%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

monitor_sqs_queues() {
  log_message INFO "Monitoring SQS queues"
  
  {
    echo "=== SQS QUEUES ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local queues_json
  queues_json=$(list_queues)
  
  local queue_urls
  queue_urls=$(echo "${queues_json}" | jq -r '.QueueUrls[]?' 2>/dev/null)
  
  if [[ -z "${queue_urls}" ]]; then
    {
      echo "No SQS queues found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local queue_count
  queue_count=$(echo "${queue_urls}" | wc -l)
  
  TOTAL_QUEUES=${queue_count}
  
  {
    echo "Total Queues: ${queue_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  while IFS= read -r queue_url; do
    [[ -z "${queue_url}" ]] && continue
    
    local queue_name
    queue_name=$(basename "${queue_url}")
    
    log_message INFO "Analyzing SQS queue: ${queue_name}"
    
    {
      echo "Queue: ${queue_name}"
      echo "URL: ${queue_url}"
    } >> "${OUTPUT_FILE}"
    
    # Get queue attributes
    local attrs_json
    attrs_json=$(get_queue_attributes "${queue_url}")
    
    local visible_count invisible_count delayed_count
    local dlq_arn retention_period visibility_timeout message_retention
    local created_timestamp
    
    visible_count=$(echo "${attrs_json}" | jq_safe '.Attributes.ApproximateNumberOfMessages // "0"')
    invisible_count=$(echo "${attrs_json}" | jq_safe '.Attributes.ApproximateNumberOfMessagesNotVisible // "0"')
    delayed_count=$(echo "${attrs_json}" | jq_safe '.Attributes.ApproximateNumberOfMessagesDelayed // "0"')
    dlq_arn=$(echo "${attrs_json}" | jq_safe '.Attributes.RedrivePolicy // "{}"' | jq -r '.deadLetterTargetArn // "None"' 2>/dev/null || echo "None")
    retention_period=$(echo "${attrs_json}" | jq_safe '.Attributes.MessageRetentionPeriod // "0"')
    visibility_timeout=$(echo "${attrs_json}" | jq_safe '.Attributes.VisibilityTimeout // "0"')
    message_retention=$(echo "${attrs_json}" | jq_safe '.Attributes.MessageRetentionPeriod // "0"')
    created_timestamp=$(echo "${attrs_json}" | jq_safe '.Attributes.CreatedTimestamp // "0"')
    
    local retention_days visibility_mins
    retention_days=$((message_retention / 86400))
    visibility_mins=$((visibility_timeout / 60))
    
    {
      echo "Messages:"
      echo "  Available: ${visible_count}"
      echo "  In Flight: ${invisible_count}"
      echo "  Delayed: ${delayed_count}"
      echo "Settings:"
      echo "  Visibility Timeout: ${visibility_mins} minutes"
      echo "  Message Retention: ${retention_days} days"
    } >> "${OUTPUT_FILE}"
    
    # Check for DLQ configuration
    if [[ "${dlq_arn}" != "None" ]]; then
      ((QUEUES_WITH_DLQ++))
      local dlq_name
      dlq_name=$(echo "${dlq_arn}" | awk -F: '{print $NF}')
      {
        echo "  Dead Letter Queue: ${dlq_name}"
      } >> "${OUTPUT_FILE}"
    else
      {
        printf "  Dead Letter Queue: %bNone configured%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Check for issues
    analyze_queue_health "${queue_name}" "${queue_url}" "${visible_count}" "${invisible_count}"
    
    # Get metrics
    analyze_queue_metrics "${queue_name}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${queue_urls}"
}

analyze_queue_health() {
  local queue_name="$1"
  local queue_url="$2"
  local visible_count="$3"
  local invisible_count="$4"
  
  {
    echo "Health Analysis:"
  } >> "${OUTPUT_FILE}"
  
  # Check queue depth
  if [[ ${visible_count} -gt ${QUEUE_DEPTH_WARN} ]]; then
    ((QUEUES_WITH_BACKLOG++))
    {
      printf "  %b⚠️  High queue depth: %d messages%b\n" "${RED}" "${visible_count}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Queue ${queue_name} has high depth: ${visible_count} messages"
  fi
  
  # Check for stuck messages (if queue has messages, get age of oldest)
  if [[ ${visible_count} -gt 0 ]]; then
    local attrs_json
    attrs_json=$(get_queue_attributes "${queue_url}")
    
    local oldest_age
    oldest_age=$(echo "${attrs_json}" | jq_safe '.Attributes.ApproximateAgeOfOldestMessage // "0"')
    
    if [[ ${oldest_age} -gt ${AGE_OF_OLDEST_WARN} ]]; then
      ((QUEUES_WITH_OLD_MESSAGES++))
      local oldest_hours
      oldest_hours=$((oldest_age / 3600))
      {
        printf "  %b⚠️  Old messages detected: oldest is %dh%b\n" "${YELLOW}" "${oldest_hours}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Queue ${queue_name} has old messages: ${oldest_hours}h"
    fi
  fi
  
  # Check if it's a DLQ with messages
  if [[ "${queue_name}" == *"dlq"* ]] || [[ "${queue_name}" == *"dead"* ]]; then
    if [[ ${visible_count} -gt ${DLQ_MESSAGE_WARN} ]]; then
      {
        printf "  %b🚨 Dead Letter Queue has %d messages%b\n" "${RED}" "${visible_count}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message ERROR "DLQ ${queue_name} has ${visible_count} messages"
    elif [[ ${visible_count} -gt 0 ]]; then
      {
        printf "  %bℹ  Dead Letter Queue has %d messages%b\n" "${CYAN}" "${visible_count}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
  fi
  
  # Check processing rate
  if [[ ${visible_count} -eq 0 ]] && [[ ${invisible_count} -eq 0 ]]; then
    {
      printf "  %b✓ Queue is empty and healthy%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_queue_metrics() {
  local queue_name="$1"
  
  {
    echo "Metrics (${LOOKBACK_HOURS}h):"
  } >> "${OUTPUT_FILE}"
  
  # Get message metrics
  local sent_json received_json deleted_json
  sent_json=$(get_sqs_metrics "${queue_name}" "NumberOfMessagesSent")
  received_json=$(get_sqs_metrics "${queue_name}" "NumberOfMessagesReceived")
  deleted_json=$(get_sqs_metrics "${queue_name}" "NumberOfMessagesDeleted")
  
  local sent_count received_count deleted_count
  sent_count=$(echo "${sent_json}" | calculate_sum)
  received_count=$(echo "${received_json}" | calculate_sum)
  deleted_count=$(echo "${deleted_json}" | calculate_sum)
  
  {
    echo "  Messages Sent: ${sent_count}"
    echo "  Messages Received: ${received_count}"
    echo "  Messages Deleted: ${deleted_count}"
  } >> "${OUTPUT_FILE}"
  
  # Calculate processing efficiency
  if [[ ${received_count} -gt 0 ]]; then
    local processing_rate
    processing_rate=$(echo "scale=2; ${deleted_count} * 100 / ${received_count}" | bc -l)
    
    {
      echo "  Processing Rate: ${processing_rate}%"
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${processing_rate} < 90" | bc -l) )); then
      {
        printf "  %b⚠️  Low processing rate - messages not being deleted%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

generate_summary() {
  {
    echo ""
    echo "=== MESSAGE FLOW SUMMARY ==="
    echo ""
    printf "SNS Topics: %d\n" "${TOTAL_TOPICS}"
    printf "SQS Queues: %d\n" "${TOTAL_QUEUES}"
    echo ""
    echo "Queue Health:"
    printf "  Queues with DLQ Configured: %d\n" "${QUEUES_WITH_DLQ}"
    printf "  Queues with Backlog: %d\n" "${QUEUES_WITH_BACKLOG}"
    printf "  Queues with Old Messages: %d\n" "${QUEUES_WITH_OLD_MESSAGES}"
    echo ""
    
    if [[ ${QUEUES_WITH_BACKLOG} -gt 0 ]] || [[ ${QUEUES_WITH_OLD_MESSAGES} -gt 0 ]]; then
      printf "%b[WARNING] Message flow issues detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] Message flow operating normally%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

optimization_recommendations() {
  {
    echo "=== OPTIMIZATION RECOMMENDATIONS ==="
    echo ""
    
    if [[ ${QUEUES_WITH_BACKLOG} -gt 0 ]]; then
      echo "Queue Backlog Remediation:"
      echo "  • Scale out consumer applications (Lambda concurrency, ECS tasks)"
      echo "  • Optimize message processing time"
      echo "  • Implement batch processing (up to 10 messages)"
      echo "  • Use FIFO queues for ordered processing (300 TPS)"
      echo "  • Consider switching to standard queues (unlimited throughput)"
      echo "  • Enable long polling to reduce API calls"
      echo "  • Use SQS Extended Client for large messages (>256KB)"
      echo ""
    fi
    
    if [[ ${QUEUES_WITH_OLD_MESSAGES} -gt 0 ]]; then
      echo "Old Message Resolution:"
      echo "  • Review visibility timeout settings (30s typical)"
      echo "  • Implement exponential backoff in consumers"
      echo "  • Check for processing errors in application logs"
      echo "  • Configure Dead Letter Queue with maxReceiveCount=3-5"
      echo "  • Monitor DLQ and implement alarm"
      echo "  • Implement message age alarms"
      echo ""
    fi
    
    echo "Dead Letter Queue Best Practices:"
    echo "  • Always configure DLQ for production queues"
    echo "  • Set maxReceiveCount based on retry needs (3-5 typical)"
    echo "  • Monitor DLQ depth with CloudWatch alarms"
    echo "  • Implement automated DLQ processing/analysis"
    echo "  • Review and replay DLQ messages after fixing issues"
    echo "  • Set shorter retention for DLQs (4 days vs 14 days)"
    echo "  • Use DLQ redrive feature for automatic replay"
    echo ""
    
    echo "SNS Optimization:"
    echo "  • Use message filtering to reduce unnecessary deliveries"
    echo "  • Enable raw message delivery for SQS subscriptions"
    echo "  • Implement retry policies (3 retries with backoff)"
    echo "  • Use SNS FIFO topics for ordered delivery"
    echo "  • Enable delivery status logging"
    echo "  • Monitor failed notifications"
    echo "  • Archive messages to S3 for audit trail"
    echo ""
    
    echo "SQS Performance Tuning:"
    echo "  • Use long polling (ReceiveMessageWaitTimeSeconds=20)"
    echo "  • Batch operations (send up to 10, receive up to 10)"
    echo "  • Optimize visibility timeout (2x processing time)"
    echo "  • Use message attributes for routing/filtering"
    echo "  • Enable content-based deduplication for FIFO"
    echo "  • Implement message groups for parallel FIFO processing"
    echo "  • Consider EventBridge for complex routing"
    echo ""
    
    echo "Cost Optimization:"
    echo "  • Use long polling to reduce API calls (64M free/month)"
    echo "  • Batch send/receive operations"
    echo "  • Delete messages after processing (no charge)"
    echo "  • Set appropriate retention (4-14 days)"
    echo "  • Use SNS message filtering to reduce SQS ingress"
    echo "  • Monitor empty receives (wasted API calls)"
    echo "  • Standard queue: 1M requests free, then $0.40/M"
    echo "  • FIFO queue: $0.50/M requests"
    echo ""
    
    echo "Monitoring & Alerts:"
    echo "  • CloudWatch alarm on ApproximateNumberOfMessagesVisible"
    echo "  • Alarm on ApproximateAgeOfOldestMessage"
    echo "  • Monitor DLQ depth (any message = alarm)"
    echo "  • Track NumberOfMessagesSent vs Deleted"
    echo "  • Monitor SNS NumberOfNotificationsFailed"
    echo "  • Use CloudWatch Logs Insights for message analysis"
    echo "  • Enable AWS X-Ray for distributed tracing"
    echo ""
    
    echo "Security Best Practices:"
    echo "  • Use SQS access policies for least-privilege"
    echo "  • Enable encryption at rest (AWS KMS)"
    echo "  • Enable encryption in transit (HTTPS only)"
    echo "  • Use VPC endpoints for private connectivity"
    echo "  • Implement SNS access policies"
    echo "  • Enable CloudTrail logging for audit"
    echo "  • Use IAM roles instead of access keys"
    echo ""
    
    echo "Architecture Patterns:"
    echo "  • Fan-out: SNS -> Multiple SQS queues"
    echo "  • Decoupling: Producer -> SQS -> Consumer"
    echo "  • Priority queues: Separate queues by priority"
    echo "  • Event sourcing: SNS -> SQS -> Event store"
    echo "  • Dead letter processing: DLQ -> Lambda -> Analysis"
    echo "  • Throttling: SQS as buffer for rate-limited APIs"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== SNS/SQS Message Flow Monitor Started ==="
  
  write_header
  monitor_sns_topics
  monitor_sqs_queues
  generate_summary
  optimization_recommendations
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS SNS Documentation: https://docs.aws.amazon.com/sns/"
    echo "AWS SQS Documentation: https://docs.aws.amazon.com/sqs/"
    echo ""
    echo "Purge queue (delete all messages):"
    echo "  aws sqs purge-queue --queue-url <url>"
    echo ""
    echo "View DLQ messages:"
    echo "  aws sqs receive-message --queue-url <dlq-url> --max-number-of-messages 10"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== SNS/SQS Message Flow Monitor Completed ==="
  
  # Send alerts
  if [[ ${QUEUES_WITH_BACKLOG} -gt 0 ]]; then
    send_slack_alert "⚠️ ${QUEUES_WITH_BACKLOG} queue(s) with high backlog detected" "WARNING"
    send_email_alert "SQS Alert: Queue Backlog" "$(cat "${OUTPUT_FILE}")"
  fi
  
  if [[ ${QUEUES_WITH_OLD_MESSAGES} -gt 0 ]]; then
    send_slack_alert "⚠️ ${QUEUES_WITH_OLD_MESSAGES} queue(s) have old unprocessed messages" "WARNING"
  fi
}

main "$@"
