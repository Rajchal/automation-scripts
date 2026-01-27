#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-dynamodb-table-monitor.log"
REPORT_FILE="/tmp/dynamodb-table-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MAX_TABLES="${DDB_MAX_TABLES:-100}"
LOOKBACK_MINUTES="${DDB_LOOKBACK_MINUTES:-5}"
READ_WARN="${DDB_READ_WARN:-1000}"
WRITE_WARN="${DDB_WRITE_WARN:-1000}"
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
  echo "DynamoDB Table Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Lookback minutes: $LOOKBACK_MINUTES" >> "$REPORT_FILE"
  echo "Read warn: $READ_WARN, Write warn: $WRITE_WARN" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

metric_max() {
  # namespace metric dimName dimValue start end period
  aws cloudwatch get-metric-statistics --namespace "$1" --metric-name "$2" --dimensions Name="$3",Value="$4" --start-time "$5" --end-time "$6" --period $7 --statistics Sum --region "$REGION" --output json 2>/dev/null | jq -r '[.Datapoints[].Sum] | max // 0'
}

main() {
  write_header

  tables_json=$(aws dynamodb list-tables --limit "$MAX_TABLES" --region "$REGION" --output json 2>/dev/null || echo '{"TableNames":[]}')
  tables=$(echo "$tables_json" | jq -r '.TableNames[]?')

  if [ -z "$tables" ]; then
    echo "No DynamoDB tables found." >> "$REPORT_FILE"
    log_message "No DynamoDB tables in region $REGION"
    exit 0
  fi

  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  start_time=$(date -u -d "${LOOKBACK_MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ)

  total=0
  alerts=0

  for t in $tables; do
    total=$((total+1))
    desc=$(aws dynamodb describe-table --table-name "$t" --region "$REGION" --output json 2>/dev/null || echo '{}')
    status=$(echo "$desc" | jq -r '.Table.TableStatus // "<unknown>"')

    read_sum=$(metric_max "AWS/DynamoDB" "ConsumedReadCapacityUnits" "TableName" "$t" "$start_time" "$now" 60)
    write_sum=$(metric_max "AWS/DynamoDB" "ConsumedWriteCapacityUnits" "TableName" "$t" "$start_time" "$now" 60)
    throttles=$(metric_max "AWS/DynamoDB" "ThrottledRequests" "TableName" "$t" "$start_time" "$now" 60 || echo 0)

    echo "Table: $t" >> "$REPORT_FILE"
    echo "Status: $status" >> "$REPORT_FILE"
    echo "ConsumedReadCapacityUnits (sum over ${LOOKBACK_MINUTES}m): $read_sum" >> "$REPORT_FILE"
    echo "ConsumedWriteCapacityUnits (sum over ${LOOKBACK_MINUTES}m): $write_sum" >> "$REPORT_FILE"
    echo "ThrottledRequests (sum): $throttles" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    read_val=$(printf '%s' "$read_sum" | awk '{print int($1)}')
    write_val=$(printf '%s' "$write_sum" | awk '{print int($1)}')
    throttles_val=$(printf '%s' "$throttles" | awk '{print int($1)}')

    if [ "$throttles_val" -gt 0 ] || [ "$read_val" -ge "$READ_WARN" ] || [ "$write_val" -ge "$WRITE_WARN" ]; then
      send_slack_alert "DynamoDB Alert: Table $t in $REGION status=$status read_sum=${read_val} write_sum=${write_val} throttles=${throttles_val}"
      alerts=$((alerts+1))
    fi
  done

  echo "Summary: total_tables=$total, alerts=$alerts" >> "$REPORT_FILE"
  log_message "DynamoDB report written to $REPORT_FILE (total_tables=$total, alerts=$alerts)"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-dynamodb-table-monitor.log"
REPORT_FILE="/tmp/dynamodb-table-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
LOOKBACK_MINUTES="${DDB_LOOKBACK_MINUTES:-5}"
READ_CAP_WARN="${DDB_READ_CAP_WARN:-80}"
WRITE_CAP_WARN="${DDB_WRITE_CAP_WARN:-80}"
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
  echo "DynamoDB Table Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Lookback (minutes): $LOOKBACK_MINUTES" >> "$REPORT_FILE"
  echo "Read cap warn: $READ_CAP_WARN%" >> "$REPORT_FILE"
  echo "Write cap warn: $WRITE_CAP_WARN%" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

get_metric_avg() {
  aws cloudwatch get-metric-statistics --namespace AWS/DynamoDB --metric-name "$1" --dimensions Name=TableName,Value="$2" --start-time "$3" --end-time "$4" --period $5 --statistics Average --region "$REGION" --output json 2>/dev/null | jq -r '[.Datapoints[].Average] | add / length // 0'
}

main() {
  write_header

  tables_json=$(aws dynamodb list-tables --region "$REGION" --output json 2>/dev/null || echo '{"TableNames":[]}')
  tables=$(echo "$tables_json" | jq -r '.TableNames[]?')

  if [ -z "$tables" ]; then
    echo "No DynamoDB tables found." >> "$REPORT_FILE"
    log_message "No DynamoDB tables in region $REGION"
    exit 0
  fi

  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  start_time=$(date -u -d "$LOOKBACK_MINUTES minutes ago" +%Y-%m-%dT%H:%M:%SZ)

  total=0
  alerts=0

  for t in $tables; do
    total=$((total+1))
    desc=$(aws dynamodb describe-table --table-name "$t" --region "$REGION" --output json 2>/dev/null || echo '{}')
    rcpu=$(echo "$desc" | jq -r '.Table.ProvisionedThroughput.ReadCapacityUnits // 0')
    wcpu=$(echo "$desc" | jq -r '.Table.ProvisionedThroughput.WriteCapacityUnits // 0')

    consumed_read=$(get_metric_avg "ConsumedReadCapacityUnits" "$t" "$start_time" "$now" 60)
    consumed_write=$(get_metric_avg "ConsumedWriteCapacityUnits" "$t" "$start_time" "$now" 60)
    read_throttle=$(aws cloudwatch get-metric-statistics --namespace AWS/DynamoDB --metric-name ReadThrottleEvents --dimensions Name=TableName,Value="$t" --start-time "$start_time" --end-time "$now" --period 60 --statistics Sum --region "$REGION" --output json 2>/dev/null | jq -r '[.Datapoints[].Sum] | add // 0')
    write_throttle=$(aws cloudwatch get-metric-statistics --namespace AWS/DynamoDB --metric-name WriteThrottleEvents --dimensions Name=TableName,Value="$t" --start-time "$start_time" --end-time "$now" --period 60 --statistics Sum --region "$REGION" --output json 2>/dev/null | jq -r '[.Datapoints[].Sum] | add // 0')

    read_pct=0
    write_pct=0
    if [ "$rcpu" -gt 0 ]; then
      read_pct=$(awk "BEGIN{printf \"%.0f\", ($consumed_read / $rcpu)*100}")
    fi
    if [ "$wcpu" -gt 0 ]; then
      write_pct=$(awk "BEGIN{printf \"%.0f\", ($consumed_write / $wcpu)*100}")
    fi

    echo "Table: $t" >> "$REPORT_FILE"
    echo "Provisioned read/write: $rcpu / $wcpu" >> "$REPORT_FILE"
    echo "Consumed read/write (avg): $consumed_read / $consumed_write" >> "$REPORT_FILE"
    echo "Read%: $read_pct%, Write%: $write_pct%" >> "$REPORT_FILE"
    echo "Read throttles: $read_throttle, Write throttles: $write_throttle" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    if [ "$read_throttle" -gt 0 ] || [ "$write_throttle" -gt 0 ] || [ "$read_pct" -ge "$READ_CAP_WARN" ] || [ "$write_pct" -ge "$WRITE_CAP_WARN" ]; then
      send_slack_alert "DynamoDB Alert: Table $t throttles R:$read_throttle W:$write_throttle read%:$read_pct write%:$write_pct"
      alerts=$((alerts+1))
    fi
  done

  echo "Summary: total_tables=$total, alerts=$alerts" >> "$REPORT_FILE"
  log_message "DynamoDB report written to $REPORT_FILE (total_tables=$total, alerts=$alerts)"
}

main "$@"
