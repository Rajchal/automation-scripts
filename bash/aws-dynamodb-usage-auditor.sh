#!/usr/bin/env bash
set -euo pipefail

# Audit DynamoDB tables for very low read/write usage (helpful to find under-utilized tables).
# Dry-run by default. Tagging requires --tag --no-dry-run.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--read-threshold N] [--write-threshold N] [--tag] [--no-dry-run]

Options:
  --region REGION        AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N               Lookback window in days for CloudWatch metrics (default: 14)
  --read-threshold N     Consider idle if total consumed read units over window <= N (default: 100)
  --write-threshold N    Consider idle if total consumed write units over window <= N (default: 100)
  --tag                  Tag candidate tables with Key=idle_candidate,Value=true
  --dry-run              Default; only print actions
  --no-dry-run           Apply tagging when requested
  -h, --help             Show this help

Example (dry-run):
  bash/aws-dynamodb-usage-auditor.sh --days 14 --read-threshold 100 --write-threshold 50

To tag candidates:
  bash/aws-dynamodb-usage-auditor.sh --tag --no-dry-run

EOF
}

REGION=""
DAYS=14
READ_THRESHOLD=100
WRITE_THRESHOLD=100
DO_TAG=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --read-threshold) READ_THRESHOLD="$2"; shift 2;;
    --write-threshold) WRITE_THRESHOLD="$2"; shift 2;;
    --tag) DO_TAG=true; shift;;
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

DDB=(aws dynamodb)
CW=(aws cloudwatch)
if [[ -n "$REGION" ]]; then
  DDB+=(--region "$REGION")
  CW+=(--region "$REGION")
fi

echo "DynamoDB auditor: days=$DAYS read_th=$READ_THRESHOLD write_th=$WRITE_THRESHOLD tag=$DO_TAG dry-run=$DRY_RUN"

end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_time=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)

tables_json=$(${DDB[*]} list-tables --output json 2>/dev/null || echo '{}')
mapfile -t tables < <(echo "$tables_json" | jq -r '.TableNames[]?')

if [[ ${#tables[@]} -eq 0 ]]; then
  echo "No DynamoDB tables found."; exit 0
fi

declare -a candidates

for tbl in "${tables[@]}"; do
  echo "Checking table $tbl"
  # consumed read units (Sum over period)
  resp_r=$(${CW[*]} get-metric-statistics --namespace AWS/DynamoDB --metric-name ConsumedReadCapacityUnits --statistics Sum --period 86400 --start-time "$start_time" --end-time "$end_time" --dimensions Name=TableName,Value=$tbl --output json 2>/dev/null || echo '{}')
  resp_w=$(${CW[*]} get-metric-statistics --namespace AWS/DynamoDB --metric-name ConsumedWriteCapacityUnits --statistics Sum --period 86400 --start-time "$start_time" --end-time "$end_time" --dimensions Name=TableName,Value=$tbl --output json 2>/dev/null || echo '{}')

  read_total=$(echo "$resp_r" | jq -r '[.Datapoints[].Sum] | add // 0')
  write_total=$(echo "$resp_w" | jq -r '[.Datapoints[].Sum] | add // 0')
  read_total=${read_total:-0}
  write_total=${write_total:-0}

  read_fmt=$(printf "%.0f" "$read_total")
  write_fmt=$(printf "%.0f" "$write_total")
  echo "  total read=${read_fmt} write=${write_fmt} over ${DAYS}d"

  if [[ $read_total -le $READ_THRESHOLD && $write_total -le $WRITE_THRESHOLD ]]; then
    candidates+=("$tbl:$read_fmt:$write_fmt")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No under-utilized DynamoDB tables found."; exit 0
fi

echo "\nCandidate under-utilized tables:"
for c in "${candidates[@]}"; do
  t=${c%%:*}
  rest=${c#*:}
  r=${rest%%:*}
  w=${rest#*:}
  echo " - $t read=${r} write=${w}"
done

if [[ "$DO_TAG" == false ]]; then
  echo "\nNo action requested. To tag these tables re-run with --tag --no-dry-run"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: would tag the candidate tables with Key=idle_candidate,Value=true. Re-run with --no-dry-run to apply."
  exit 0
fi

echo "Tagging candidate tables..."
for c in "${candidates[@]}"; do
  t=${c%%:*}
  echo "Tagging $t"
  arn=$(${DDB[*]} list-tags-of-resource --resource-arn $(aws dynamodb describe-table --table-name "$t" --query 'Table.TableArn' --output text) --output json 2>/dev/null >/dev/null || true)
  # Simpler: use tag-resource for DynamoDB tables via resource ARN
  table_arn=$(aws dynamodb describe-table --table-name "$t" --query 'Table.TableArn' --output text)
  if [[ -n "$table_arn" && "$table_arn" != "None" ]]; then
    aws dynamodb tag-resource --resource-arn "$table_arn" --tags Key=idle_candidate,Value=true || echo "Failed to tag $t"
  else
    echo "  Could not determine ARN for $t; skipping tag.";
  fi
done

echo "Done."
