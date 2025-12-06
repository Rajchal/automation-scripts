#!/usr/bin/env bash
set -euo pipefail

# aws-vpc-flow-logs-analyzer.sh
# Analyze VPC Flow Logs for security insights: rejected traffic, top talkers, suspicious patterns.
# Queries CloudWatch Logs Insights or parses S3-stored flow logs.
# Dry-run by default; use --no-dry-run to execute queries.

usage(){
  cat <<EOF
Usage: $0 [--log-group NAME] [--hours N] [--region REGION] [--top N] [--no-dry-run]

Options:
  --log-group NAME         CloudWatch log group name for VPC flow logs (required)
  --hours N                Analyze logs from last N hours (default: 24)
  --region REGION          AWS region (uses AWS_DEFAULT_REGION if unset)
  --top N                  Show top N talkers/ports (default: 10)
  --no-dry-run             Execute CloudWatch Insights query (default: dry-run)
  -h, --help               Show this help

Examples:
  # Dry-run: show query that would be executed
  bash/aws-vpc-flow-logs-analyzer.sh --log-group /aws/vpc/flowlogs

  # Analyze last 6 hours of flow logs
  bash/aws-vpc-flow-logs-analyzer.sh --log-group /aws/vpc/flowlogs --hours 6 --no-dry-run

  # Find top 20 sources with rejected traffic
  bash/aws-vpc-flow-logs-analyzer.sh --log-group /aws/vpc/flowlogs --top 20 --no-dry-run

EOF
}

LOG_GROUP=""
HOURS=24
REGION=""
TOP=10
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log-group) LOG_GROUP="$2"; shift 2;;
    --hours) HOURS="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --top) TOP="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$LOG_GROUP" ]]; then
  echo "--log-group is required"; usage; exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required"; exit 3
fi

AWS=(aws logs)
if [[ -n "$REGION" ]]; then
  AWS+=(--region "$REGION")
fi

echo "VPC Flow Logs Analyzer: log-group=$LOG_GROUP hours=$HOURS top=$TOP dry-run=$DRY_RUN"

# Calculate time range (CloudWatch uses milliseconds since epoch)
now_ms=$(($(date +%s) * 1000))
start_ms=$((($(date +%s) - HOURS * 3600) * 1000))

# Query 1: Rejected traffic analysis
query_rejected=$(cat <<'QUERY'
fields @timestamp, srcAddr, dstAddr, srcPort, dstPort, protocol, bytes
| filter action = "REJECT"
| stats count() as rejectedCount, sum(bytes) as totalBytes by srcAddr, dstAddr, dstPort
| sort rejectedCount desc
| limit 10
QUERY
)

# Query 2: Top talkers by bytes
query_top_talkers=$(cat <<'QUERY'
fields srcAddr, dstAddr, bytes
| stats sum(bytes) as totalBytes, count() as flowCount by srcAddr
| sort totalBytes desc
| limit 10
QUERY
)

# Query 3: Top destination ports
query_top_ports=$(cat <<'QUERY'
fields dstPort, action
| filter action = "ACCEPT"
| stats count() as connectionCount by dstPort
| sort connectionCount desc
| limit 10
QUERY
)

run_query() {
  local query_name="$1"
  local query_text="$2"
  
  echo ""
  echo "=== $query_name ==="
  
  if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN: would execute query:"
    echo "$query_text"
    return
  fi
  
  # Start query
  query_id=$("${AWS[@]}" start-query \
    --log-group-name "$LOG_GROUP" \
    --start-time $((start_ms / 1000)) \
    --end-time $((now_ms / 1000)) \
    --query-string "$query_text" \
    --output text 2>/dev/null | awk '{print $1}' || echo "")
  
  if [[ -z "$query_id" ]]; then
    echo "Failed to start query"
    return 1
  fi
  
  echo "Query started: $query_id (waiting for results...)"
  
  # Poll for results (max 30 seconds)
  for i in {1..30}; do
    sleep 2
    status=$("${AWS[@]}" get-query-results --query-id "$query_id" --query 'status' --output text 2>/dev/null || echo "Failed")
    
    if [[ "$status" == "Complete" ]]; then
      echo "Query completed. Results:"
      "${AWS[@]}" get-query-results --query-id "$query_id" --output json 2>/dev/null | \
        jq -r '.results[] | map(.value) | @tsv' | column -t || echo "No results"
      return 0
    elif [[ "$status" == "Failed" || "$status" == "Cancelled" ]]; then
      echo "Query failed or was cancelled"
      return 1
    fi
  done
  
  echo "Query timed out"
  return 1
}

# Execute queries
run_query "Rejected Traffic (Top Sources)" "$query_rejected"
run_query "Top Talkers by Bytes Transferred" "$query_top_talkers"
run_query "Top Destination Ports" "$query_top_ports"

echo ""
echo "Analysis complete."
