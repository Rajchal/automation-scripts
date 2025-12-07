#!/usr/bin/env bash
set -euo pipefail

# prometheus-metrics-monitor.sh
# Query Prometheus metrics and generate alerts based on thresholds.
# Supports PromQL queries with customizable alerting rules.
# Dry-run by default; use --no-dry-run to enable monitoring.

usage(){
  cat <<EOF
Usage: $0 --prometheus-url URL [--query QUERY] [--threshold VALUE] [--slack-webhook URL] [--no-dry-run]

Options:
  --prometheus-url URL     Prometheus server URL (required)
  --query QUERY            PromQL query to execute (required)
  --threshold VALUE        Alert threshold value (required)
  --operator OP            Comparison operator: gt, lt, ge, le, eq (default: gt)
  --metric-name NAME       Friendly name for the metric
  --slack-webhook URL      Slack webhook URL for alerts
  --email TO               Email address for alerts
  --no-dry-run             Execute monitoring (default: dry-run)
  -h, --help               Show this help

Examples:
  # Dry-run: show what would be monitored
  bash/prometheus-metrics-monitor.sh --prometheus-url http://localhost:9090 --query 'up' --threshold 0

  # Alert if CPU usage > 80%
  bash/prometheus-metrics-monitor.sh \\
    --prometheus-url http://prometheus.example.com:9090 \\
    --query 'avg(rate(cpu_usage[5m])) * 100' \\
    --threshold 80 \\
    --metric-name "CPU Usage" \\
    --slack-webhook https://hooks.slack.com/... \\
    --no-dry-run

  # Alert if memory available < 10GB
  bash/prometheus-metrics-monitor.sh \\
    --prometheus-url http://prometheus.example.com:9090 \\
    --query 'node_memory_MemAvailable_bytes / 1024 / 1024 / 1024' \\
    --threshold 10 \\
    --operator lt \\
    --metric-name "Memory Available" \\
    --no-dry-run

  # Cron job to check every minute
  * * * * * /path/to/prometheus-metrics-monitor.sh --prometheus-url URL --query QUERY --threshold N --no-dry-run

EOF
}

PROMETHEUS_URL=""
QUERY=""
THRESHOLD=""
OPERATOR="gt"
METRIC_NAME=""
SLACK_WEBHOOK=""
EMAIL=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prometheus-url) PROMETHEUS_URL="$2"; shift 2;;
    --query) QUERY="$2"; shift 2;;
    --threshold) THRESHOLD="$2"; shift 2;;
    --operator) OPERATOR="$2"; shift 2;;
    --metric-name) METRIC_NAME="$2"; shift 2;;
    --slack-webhook) SLACK_WEBHOOK="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$PROMETHEUS_URL" ]]; then
  echo "--prometheus-url is required"; usage; exit 2
fi

if [[ -z "$QUERY" ]]; then
  echo "--query is required"; usage; exit 2
fi

if [[ -z "$THRESHOLD" ]]; then
  echo "--threshold is required"; usage; exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required"; exit 3
fi

# Remove trailing slash from Prometheus URL
PROMETHEUS_URL="${PROMETHEUS_URL%/}"

# Set default metric name
if [[ -z "$METRIC_NAME" ]]; then
  METRIC_NAME="$QUERY"
fi

echo "Prometheus Metrics Monitor: metric='$METRIC_NAME' threshold=$THRESHOLD operator=$OPERATOR dry-run=$DRY_RUN"

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: would execute query and check threshold"
  echo "Query: $QUERY"
  exit 0
fi

# Function to send Slack notification
send_slack_alert() {
  local message="$1"
  
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -s -X POST "$SLACK_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "{\"text\":\"$message\"}" >/dev/null 2>&1 || echo "Failed to send Slack alert"
  fi
}

# Function to send email
send_email_alert() {
  local subject="$1"
  local body="$2"
  
  if [[ -n "$EMAIL" ]] && command -v mail >/dev/null 2>&1; then
    echo "$body" | mail -s "$subject" "$EMAIL" 2>/dev/null || echo "Failed to send email"
  fi
}

# Function to compare values
compare_values() {
  local value="$1"
  local threshold="$2"
  local op="$3"
  
  case "$op" in
    gt) result=$(echo "$value > $threshold" | bc -l 2>/dev/null || echo 0);;
    lt) result=$(echo "$value < $threshold" | bc -l 2>/dev/null || echo 0);;
    ge) result=$(echo "$value >= $threshold" | bc -l 2>/dev/null || echo 0);;
    le) result=$(echo "$value <= $threshold" | bc -l 2>/dev/null || echo 0);;
    eq) result=$(echo "$value == $threshold" | bc -l 2>/dev/null || echo 0);;
    *) result=0;;
  esac
  
  echo "$result"
}

# URL encode the query
encoded_query=$(printf %s "$QUERY" | jq -sRr @uri)

# Execute Prometheus query
echo "Executing query..."
response=$(curl -s "$PROMETHEUS_URL/api/v1/query?query=$encoded_query" 2>/dev/null || echo '{}')

# Check if query was successful
status=$(echo "$response" | jq -r '.status // "error"')

if [[ "$status" != "success" ]]; then
  error_msg=$(echo "$response" | jq -r '.error // "Unknown error"')
  echo "Query failed: $error_msg"
  exit 1
fi

# Extract result values
result_type=$(echo "$response" | jq -r '.data.resultType // "unknown"')

if [[ "$result_type" == "vector" ]]; then
  # Vector result (instant query)
  mapfile -t results < <(echo "$response" | jq -c '.data.result[]?')
  
  if [[ ${#results[@]} -eq 0 ]]; then
    echo "No results returned from query"
    exit 0
  fi
  
  echo "Found ${#results[@]} result(s)"
  echo ""
  
  declare -i alert_count=0
  
  for result in "${results[@]}"; do
    metric=$(echo "$result" | jq -r '.metric | to_entries | map("\(.key)=\(.value)") | join(", ")')
    value=$(echo "$result" | jq -r '.value[1]')
    
    # Compare value with threshold
    triggered=$(compare_values "$value" "$THRESHOLD" "$OPERATOR")
    
    if [[ "$triggered" -eq 1 ]]; then
      echo "🔴 ALERT: $METRIC_NAME"
      echo "  Metric: {$metric}"
      echo "  Value: $value"
      echo "  Threshold: $OPERATOR $THRESHOLD"
      
      ((alert_count++))
      
      alert_msg="🔴 Prometheus Alert: $METRIC_NAME\nValue: $value (threshold: $OPERATOR $THRESHOLD)\nMetric: {$metric}\nQuery: $QUERY"
      send_slack_alert "$alert_msg"
      send_email_alert "Prometheus Alert: $METRIC_NAME" "$alert_msg"
    else
      echo "✓ OK: $METRIC_NAME"
      echo "  Metric: {$metric}"
      echo "  Value: $value"
      echo "  Threshold: $OPERATOR $THRESHOLD"
    fi
  done
  
  if [[ $alert_count -gt 0 ]]; then
    echo ""
    echo "=== Summary ==="
    echo "Alerts triggered: $alert_count"
    exit 1
  else
    echo ""
    echo "All metrics within threshold"
    exit 0
  fi
  
elif [[ "$result_type" == "matrix" ]]; then
  # Range query result
  echo "Range query result - showing latest values"
  
  mapfile -t results < <(echo "$response" | jq -c '.data.result[]?')
  
  declare -i alert_count=0
  
  for result in "${results[@]}"; do
    metric=$(echo "$result" | jq -r '.metric | to_entries | map("\(.key)=\(.value)") | join(", ")')
    
    # Get the last value from the values array
    value=$(echo "$result" | jq -r '.values[-1][1]')
    
    triggered=$(compare_values "$value" "$THRESHOLD" "$OPERATOR")
    
    if [[ "$triggered" -eq 1 ]]; then
      echo "🔴 ALERT: $METRIC_NAME"
      echo "  Metric: {$metric}"
      echo "  Latest value: $value"
      echo "  Threshold: $OPERATOR $THRESHOLD"
      
      ((alert_count++))
      
      alert_msg="🔴 Prometheus Alert: $METRIC_NAME\nLatest value: $value (threshold: $OPERATOR $THRESHOLD)\nMetric: {$metric}"
      send_slack_alert "$alert_msg"
      send_email_alert "Prometheus Alert: $METRIC_NAME" "$alert_msg"
    else
      echo "✓ OK: $METRIC_NAME"
      echo "  Metric: {$metric}"
      echo "  Latest value: $value"
    fi
  done
  
  if [[ $alert_count -gt 0 ]]; then
    exit 1
  else
    exit 0
  fi
  
elif [[ "$result_type" == "scalar" ]]; then
  # Scalar result (single value)
  timestamp=$(echo "$response" | jq -r '.data.result[0]')
  value=$(echo "$response" | jq -r '.data.result[1]')
  
  triggered=$(compare_values "$value" "$THRESHOLD" "$OPERATOR")
  
  if [[ "$triggered" -eq 1 ]]; then
    echo "🔴 ALERT: $METRIC_NAME"
    echo "  Value: $value"
    echo "  Threshold: $OPERATOR $THRESHOLD"
    
    alert_msg="🔴 Prometheus Alert: $METRIC_NAME\nValue: $value (threshold: $OPERATOR $THRESHOLD)\nQuery: $QUERY"
    send_slack_alert "$alert_msg"
    send_email_alert "Prometheus Alert: $METRIC_NAME" "$alert_msg"
    
    exit 1
  else
    echo "✓ OK: $METRIC_NAME"
    echo "  Value: $value"
    echo "  Threshold: $OPERATOR $THRESHOLD"
    exit 0
  fi
else
  echo "Unknown result type: $result_type"
  exit 1
fi
