#!/usr/bin/env bash
set -euo pipefail

# Audit SNS topics for no subscriptions and low publish activity.
# Dry-run by default. Tagging or deletion requires --no-dry-run.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--msg-threshold N] [--tag] [--delete] [--no-dry-run]

Options:
  --region REGION       AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N              Lookback window in days for CloudWatch metric (default: 14)
  --msg-threshold N     Consider idle if total published messages over window <= N (default: 0)
  --tag                 Tag candidate topics with Key=idle_candidate,Value=true
  --delete              Delete topics with zero subscriptions (dangerous)
  --dry-run             Default; only print actions
  --no-dry-run          Apply tagging/deletion when requested
  -h, --help            Show this help

Example (dry-run):
  bash/aws-sns-unused-topic-auditor.sh --days 14 --msg-threshold 0

To tag candidates:
  bash/aws-sns-unused-topic-auditor.sh --tag --no-dry-run

To delete (dangerous):
  bash/aws-sns-unused-topic-auditor.sh --delete --no-dry-run

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

SNS=(aws sns)
CW=(aws cloudwatch)
if [[ -n "$REGION" ]]; then
  SNS+=(--region "$REGION")
  CW+=(--region "$REGION")
fi

echo "SNS auditor: days=$DAYS msg-threshold=$MSG_THRESHOLD tag=$DO_TAG delete=$DO_DELETE dry-run=$DRY_RUN"

end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_time=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)

topics_json=$(${SNS[*]} list-topics --output json 2>/dev/null || echo '{}')
mapfile -t topics < <(echo "$topics_json" | jq -r '.Topics[]?.TopicArn' )

if [[ ${#topics[@]} -eq 0 ]]; then
  echo "No SNS topics found."; exit 0
fi

declare -a candidates

for arn in "${topics[@]}"; do
  # Count subscriptions
  sub_count=$(${SNS[*]} list-subscriptions-by-topic --topic-arn "$arn" --output json 2>/dev/null | jq -r '.Subscriptions | length')
  if [[ -z "$sub_count" ]]; then sub_count=0; fi

  # CloudWatch metric: NumberOfNotificationsPublished or NumberOfMessagesPublished may vary; try common names
  metric_names=("NumberOfNotificationsPublished" "NumberOfMessagesPublished" "PublishSize")
  total=0
  for m in "${metric_names[@]}"; do
    resp=$(${CW[*]} get-metric-statistics --namespace AWS/SNS --metric-name "$m" --statistics Sum --period 86400 --start-time "$start_time" --end-time "$end_time" --dimensions Name=TopicName,Value=$(basename "$arn") --output json 2>/dev/null || echo '{}')
    sum=$(echo "$resp" | jq -r '[.Datapoints[].Sum] | add // 0')
    sum=${sum:-0}
    total=$(awk -v a="$total" -v b="$sum" 'BEGIN{printf("%d", a + b)}')
  done

  echo "Topic $(basename "$arn"): subs=$sub_count total_publishes=$total"
  if [[ $sub_count -eq 0 && $total -le $MSG_THRESHOLD ]]; then
    candidates+=("$arn:$sub_count:$total")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No idle SNS topics found."; exit 0
fi

echo "\nCandidate idle topics:"
for c in "${candidates[@]}"; do
  arn=${c%%:*}
  rest=${c#*:}
  subs=${rest%%:*}
  total=${rest#*:}
  echo " - $arn subs=$subs publishes=$total"
done

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: no tags or deletes performed. Re-run with --no-dry-run and --tag/--delete to act."
  exit 0
fi

if [[ "$DO_TAG" == true ]]; then
  echo "\nTagging candidate topics..."
  for c in "${candidates[@]}"; do
    arn=${c%%:*}
    echo "Tagging $arn"
    ${SNS[*]} tag-resource --resource-arn "$arn" --tags Key=idle_candidate,Value=true || echo "Failed to tag $arn"
  done
fi

if [[ "$DO_DELETE" == true ]]; then
  echo "\nDeleting candidate topics (will only delete topics without subscriptions)..."
  for c in "${candidates[@]}"; do
    arn=${c%%:*}
    echo "Deleting $arn"
    ${SNS[*]} delete-topic --topic-arn "$arn" || echo "Failed to delete $arn"
  done
fi

echo "Done."
