#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-cloudwatch-alarms-check.log"
REPORT_FILE="/tmp/cloudwatch-alarms-check-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -z "$SLACK_WEBHOOK" ]; then
    return
  fi
  payload=$(jq -n --arg t "$1" '{"text":$t}')
  curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
}

write_header() {
  echo "CloudWatch Alarms Check - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  alarms_json=$(aws cloudwatch describe-alarms --state-value ALARM --region "$REGION" --output json 2>/dev/null || echo '{"MetricAlarms":[]}')
  count=$(echo "$alarms_json" | jq '.MetricAlarms | length')

  if [ "$count" -eq 0 ]; then
    echo "No alarms in ALARM state." >> "$REPORT_FILE"
    log_message "No CloudWatch alarms in ALARM state in $REGION"
    exit 0
  fi

  echo "Found $count alarms in ALARM state" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  echo "$alarms_json" | jq -c '.MetricAlarms[]' | while read -r a; do
    name=$(echo "$a" | jq -r '.AlarmName')
    ns=$(echo "$a" | jq -r '.Namespace // .Namespace')
    metric=$(echo "$a" | jq -r '.MetricName // "<composite>"')
    dims=$(echo "$a" | jq -r '.Dimensions[]? | "\(.Name)=\(.Value)"' | paste -sd"," -)
    state_reason=$(echo "$a" | jq -r '.StateReason // "<no-reason>"')
    state_updated=$(echo "$a" | jq -r '.StateUpdatedTimestamp // "<unknown>"')

    echo "Alarm: $name" >> "$REPORT_FILE"
    echo "  Metric: ${metric}" >> "$REPORT_FILE"
    echo "  Namespace: ${ns}" >> "$REPORT_FILE"
    echo "  Dimensions: ${dims}" >> "$REPORT_FILE"
    echo "  State reason: ${state_reason}" >> "$REPORT_FILE"
    echo "  State updated: ${state_updated}" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    send_slack_alert "CloudWatch ALARM: $name — metric=${metric} namespace=${ns} dims=${dims} reason=${state_reason} updated=${state_updated}"
  done

  log_message "CloudWatch alarms report written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

# List CloudWatch alarms in ALARM state and optionally publish a summary to SNS.
# Usage: aws-cloudwatch-alarms-check.sh [--sns-topic arn:aws:sns:...] [--dry-run]

usage(){
  cat <<EOF
Usage: $0 [--sns-topic SNS_ARN] [--dry-run]

Options:
  --sns-topic ARN  Optional SNS topic to publish a summary to
  --dry-run       Do not publish to SNS (default)
  -h              Help
EOF
}

SNS_TOPIC=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sns-topic) SNS_TOPIC="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown $1"; usage; exit 2;;
  esac
done

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI required"; exit 3
fi

alarms=$(aws cloudwatch describe-alarms --state-value ALARM --query 'MetricAlarms[] | [].[AlarmName,AlarmArn,StateUpdatedTimestamp,StateReason]' --output json)

count=$(echo "$alarms" | jq 'length')
echo "Found $count alarm(s) in ALARM state"

if [[ $count -eq 0 ]]; then
  exit 0
fi

summary=$(echo "$alarms" | jq -r '.[] | "Name: \(.[] | tostring)"' | sed 's/^/ - /')
echo "$summary"

if [[ -n "$SNS_TOPIC" ]]; then
  payload="CloudWatch alarms in ALARM state:\n$count\n$summary"
  if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN: aws sns publish --topic-arn $SNS_TOPIC --message \"$payload\""
  else
    aws sns publish --topic-arn "$SNS_TOPIC" --message "$payload"
    echo "Published summary to $SNS_TOPIC"
  fi
fi

echo "Done."
