#!/usr/bin/env bash
set -euo pipefail

# Find SQS queues that appear unused (low or zero messages and low receive/send activity)
# Dry-run by default. Optionally tag (via queue attributes) or delete queues when explicitly requested.
# Usage: aws-sqs-unused-queue-auditor.sh [--region REGION] [--days N] [--msg-threshold N] [--tag] [--delete] [--no-dry-run]

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--msg-threshold N] [--tag] [--delete] [--no-dry-run]

Options:
  --region REGION       AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N              Lookback window in days for CloudWatch metrics (default: 14)
  --msg-threshold N     Consider queue unused if ApproximateNumberOfMessagesVisible <= N (default: 0)
  --tag                 Tag candidate queues by adding a tag Key=idle_candidate,Value=true (requires --no-dry-run)
  --delete              Delete candidate queues (requires --no-dry-run; use with caution)
  --dry-run             Default; only print actions
  --no-dry-run          Perform tagging/deletion when requested
  -h, --help            Show this help

Example (dry-run):
  bash/aws-sqs-unused-queue-auditor.sh --days 14 --msg-threshold 0

To tag candidates:
  bash/aws-sqs-unused-queue-auditor.sh --days 14 --msg-threshold 0 --tag --no-dry-run

To delete candidates (dangerous):
  bash/aws-sqs-unused-queue-auditor.sh --days 14 --msg-threshold 0 --delete --no-dry-run

EOF
}

REGION=""
DAYS=14
MSG_THRESHOLD=0
DO_TAG=false
DO_DELETE=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --msg-threshold) MSG_THRESHOLD="$2"; shift 2;;
    --tag) DO_TAG=true; shift;;
    --delete) DO_DELETE=true; shift;;
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

AWS_SQS=(aws sqs)
CW=(aws cloudwatch)
if [[ -n "$REGION" ]]; then
  AWS_SQS+=(--region "$REGION")
  CW+=(--region "$REGION")
fi

echo "SQS auditor: days=$DAYS msg-threshold=$MSG_THRESHOLD tag=$DO_TAG delete=$DO_DELETE dry-run=$DRY_RUN"

echo "Listing queues..."
queues_json=$(${AWS_SQS[*]} list-queues --output json 2>/dev/null || echo '{}')
mapfile -t queues < <(echo "$queues_json" | jq -r '.QueueUrls[]?')

if [[ ${#queues[@]} -eq 0 ]]; then
  echo "No SQS queues found."; exit 0
fi

start_time=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)
end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

declare -a candidates

for q in "${queues[@]}"; do
  # Get approximate number of visible messages attribute
  attrs=$(${AWS_SQS[*]} get-queue-attributes --queue-url "$q" --attribute-names ApproximateNumberOfMessages --output json 2>/dev/null || echo '{}')
  visible=$(echo "$attrs" | jq -r '.Attributes.ApproximateNumberOfMessages // 0')
  if [[ -z "$visible" ]]; then visible=0; fi
  echo "Queue $q: approx visible messages = $visible"
  if [[ $visible -gt $MSG_THRESHOLD ]]; then
    echo "  Skipping: message count > threshold"
    continue
  fi

  # Evaluate CloudWatch metrics ReceiveMessageCount and SendMessageCount over the window
  recv=$(${CW[*]} get-metric-statistics --namespace AWS/SQS --metric-name NumberOfMessagesReceived --statistics Sum --period 86400 --start-time "$start_time" --end-time "$end_time" --dimensions Name=QueueName,Value=$(basename "$q") --output json 2>/dev/null || echo '{}')
  sent=$(${CW[*]} get-metric-statistics --namespace AWS/SQS --metric-name NumberOfMessagesSent --statistics Sum --period 86400 --start-time "$start_time" --end-time "$end_time" --dimensions Name=QueueName,Value=$(basename "$q") --output json 2>/dev/null || echo '{}')
  recv_total=$(echo "$recv" | jq -r '[.Datapoints[].Sum] | add // 0')
  sent_total=$(echo "$sent" | jq -r '[.Datapoints[].Sum] | add // 0')
  recv_total=${recv_total:-0}
  sent_total=${sent_total:-0}

  echo "  messages received over ${DAYS}d = $recv_total; messages sent = $sent_total"

  if [[ $recv_total -eq 0 && $sent_total -eq 0 ]]; then
    candidates+=("$q")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No unused queues found."; exit 0
fi

echo "\nCandidate unused queues:"
for c in "${candidates[@]}"; do
  echo " - $c"
done

if [[ "$DO_TAG" == false && "$DO_DELETE" == false ]]; then
  echo "\nNo action requested. To tag candidates use --tag --no-dry-run; to delete use --delete --no-dry-run"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: no changes will be made. Re-run with --no-dry-run to perform actions."
  exit 0
fi

for c in "${candidates[@]}"; do
  if [[ "$DO_TAG" == true ]]; then
    echo "Tagging queue $c with idle_candidate=true"
    ${AWS_SQS[*]} tag-queue --queue-url "$c" --tags idle_candidate=true
  fi
  if [[ "$DO_DELETE" == true ]]; then
    echo "Deleting queue $c"
    ${AWS_SQS[*]} delete-queue --queue-url "$c"
  fi
done

echo "Done."
