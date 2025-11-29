#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 --threshold AMOUNT [--days N] [--region REGION]

Checks AWS cost for the past N days (default 1) using Cost Explorer and exits non-zero
if the total cost exceeds --threshold. Threshold is in USD (decimal allowed).

Requires: AWS Cost Explorer permissions and aws cli v2.
Example: $0 --threshold 50 --days 7
EOF
}

THRESHOLD=""
DAYS=1
REGION="us-east-1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold) THRESHOLD="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$THRESHOLD" ]]; then echo "--threshold is required"; usage; exit 2; fi

END=$(date -u +%Y-%m-%d)
START=$(date -u -d "${DAYS} days ago" +%Y-%m-%d)

echo "Checking AWS cost from $START to $END (threshold: $THRESHOLD USD)"

TOTAL=$(
  aws --region "$REGION" ce get-cost-and-usage --time-period Start=$START,End=$END --granularity DAILY --metrics "UnblendedCost" --query 'ResultsByTime[].Total.UnblendedCost.Amount' --output text | \
  awk '{s+= $1} END {printf "%.2f", s}'
)

echo "Total cost: $TOTAL USD"

# Compare as floats
awk -v t="$TOTAL" -v th="$THRESHOLD" 'BEGIN{ if (t+0 > th+0) exit 1; else exit 0 }'
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
  echo "ALERT: cost exceeded threshold"; exit 2
else
  echo "Cost within threshold"; exit 0
fi
