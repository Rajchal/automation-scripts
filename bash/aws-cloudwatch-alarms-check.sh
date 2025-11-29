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
