#!/usr/bin/env bash
set -euo pipefail

# aws-detailed-cost-report.sh
# Generate detailed cost breakdown by AWS service using AWS Cost Explorer API.
# Exports results to CSV and console report.
# Dry-run by default (console only); use --no-dry-run to save CSV.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--granularity DAILY|MONTHLY] [--output FILE] [--no-dry-run]

Options:
  --region REGION             AWS region for API calls (default: us-east-1)
  --days N                    Lookback window in days (default: 30)
  --granularity GRANULARITY   Daily or Monthly granularity (default: DAILY)
  --output FILE               CSV output filename (default: cost-report-TIMESTAMP.csv)
  --no-dry-run                Write CSV report (default: console output only)
  -h, --help                  Show this help

Examples:
  # Dry-run: show cost breakdown by service for last 30 days (console)
  bash/aws-detailed-cost-report.sh

  # Generate monthly breakdown and save to CSV
  bash/aws-detailed-cost-report.sh --days 90 --granularity MONTHLY --no-dry-run

  # Custom output file
  bash/aws-detailed-cost-report.sh --output my-costs.csv --no-dry-run

EOF
}

REGION="us-east-1"
DAYS=30
GRANULARITY="DAILY"
OUTPUT_FILE=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --granularity) GRANULARITY="$2"; shift 2;;
    --output) OUTPUT_FILE="$2"; shift 2;;
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

if [[ -z "$OUTPUT_FILE" ]]; then
  OUTPUT_FILE="cost-report-$(date +%s).csv"
fi

case "$GRANULARITY" in
  DAILY|MONTHLY) ;;
  *) echo "Invalid granularity: $GRANULARITY"; exit 2;;
esac

echo "Detailed cost report: days=$DAYS granularity=$GRANULARITY dry-run=$DRY_RUN"

end_date=$(date -u +%Y-%m-%d)
start_date=$(date -u -d "$DAYS days ago" +%Y-%m-%d)

echo "Period: $start_date to $end_date"
echo ""

# Call Cost Explorer API
cost_data=$(aws ce get-cost-and-usage \
  --region "$REGION" \
  --time-period Start="$start_date",End="$end_date" \
  --granularity "$GRANULARITY" \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --output json 2>/dev/null || echo '{}')

# Parse and display results
results=$(echo "$cost_data" | jq -c '.ResultsByTime[]? | {TimePeriod: .TimePeriod, Groups: .Groups[]?}' 2>/dev/null || echo '')

declare -a costs_by_service
declare -i total_cost=0

if [[ -n "$results" ]]; then
  mapfile -t line_items < <(echo "$cost_data" | jq -r '.ResultsByTime[] | .Groups[] | [.Keys[0], .Metrics.UnblendedCost.Amount] | @csv' 2>/dev/null)
  
  echo "=== Cost Breakdown by Service ==="
  for item in "${line_items[@]}"; do
    service=$(echo "$item" | cut -d',' -f1 | tr -d '"')
    amount=$(echo "$item" | cut -d',' -f2 | tr -d '"')
    
    # Accumulate for totals
    costs_by_service+=("$service|$amount")
    
    # Print with formatting
    printf "%-40s \$%10.2f\n" "$service" "$amount"
  done
  
  echo ""
  total_cost=$(echo "${costs_by_service[@]}" | tr ' ' '\n' | cut -d'|' -f2 | awk '{sum+=$1} END {printf "%.2f", sum}')
  printf "%-40s \$%10s\n" "TOTAL" "$total_cost"
fi

if [[ "$DRY_RUN" == false ]]; then
  echo ""
  echo "Writing detailed report to: $OUTPUT_FILE"
  {
    echo "Service,Cost,Currency,Period"
    for item in "${costs_by_service[@]}"; do
      IFS='|' read -r service cost <<< "$item"
      echo "$service,$cost,USD,$start_date to $end_date"
    done
    echo "TOTAL,$total_cost,USD,$start_date to $end_date"
  } > "$OUTPUT_FILE"
  
  echo "Report saved successfully."
fi

echo "Done."
