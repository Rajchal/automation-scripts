#!/usr/bin/env bash
set -euo pipefail

# redis-health-monitor.sh
# Monitor Redis server health, performance metrics, and generate alerts.
# Checks memory usage, connected clients, replication lag, and more.
# Dry-run by default; use --no-dry-run to enable monitoring.

usage(){
  cat <<EOF
Usage: $0 [--host HOST] [--port PORT] [--password PASS] [--memory-threshold PCT] [--no-dry-run]

Options:
  --host HOST              Redis host (default: localhost)
  --port PORT              Redis port (default: 6379)
  --password PASS          Redis password (optional)
  --memory-threshold PCT   Alert if memory usage > N% (default: 80)
  --clients-threshold N    Alert if connected clients > N (default: 1000)
  --ops-threshold N        Alert if ops/sec > N (default: 10000)
  --slack-webhook URL      Slack webhook URL for alerts
  --email TO               Email address for alerts
  --no-dry-run             Enable monitoring (default: dry-run)
  -h, --help               Show this help

Examples:
  # Dry-run: show what would be monitored
  bash/redis-health-monitor.sh

  # Monitor local Redis instance
  bash/redis-health-monitor.sh --host localhost --port 6379 --no-dry-run

  # Monitor with authentication and custom thresholds
  bash/redis-health-monitor.sh \\
    --host redis.example.com \\
    --port 6379 \\
    --password secret123 \\
    --memory-threshold 90 \\
    --clients-threshold 500 \\
    --slack-webhook https://hooks.slack.com/... \\
    --no-dry-run

  # Cron job to check every 5 minutes
  */5 * * * * /path/to/redis-health-monitor.sh --host redis-prod --password PASS --no-dry-run

EOF
}

HOST="localhost"
PORT=6379
PASSWORD=""
MEMORY_THRESHOLD=80
CLIENTS_THRESHOLD=1000
OPS_THRESHOLD=10000
SLACK_WEBHOOK=""
EMAIL=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --password) PASSWORD="$2"; shift 2;;
    --memory-threshold) MEMORY_THRESHOLD="$2"; shift 2;;
    --clients-threshold) CLIENTS_THRESHOLD="$2"; shift 2;;
    --ops-threshold) OPS_THRESHOLD="$2"; shift 2;;
    --slack-webhook) SLACK_WEBHOOK="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if ! command -v redis-cli >/dev/null 2>&1; then
  echo "redis-cli required"; exit 3
fi

echo "Redis Health Monitor: host=$HOST:$PORT memory-threshold=${MEMORY_THRESHOLD}% dry-run=$DRY_RUN"

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: would monitor Redis server health and performance"
  exit 0
fi

# Build redis-cli command
REDIS_CMD=(redis-cli -h "$HOST" -p "$PORT")
if [[ -n "$PASSWORD" ]]; then
  REDIS_CMD+=(-a "$PASSWORD" --no-auth-warning)
fi

# Function to send Slack alert
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

# Test connection
echo "Testing Redis connection..."
if ! "${REDIS_CMD[@]}" PING >/dev/null 2>&1; then
  echo "❌ Failed to connect to Redis at $HOST:$PORT"
  
  alert_msg="🔴 Redis Alert: Cannot connect to Redis server\nHost: $HOST:$PORT"
  send_slack_alert "$alert_msg"
  send_email_alert "Redis: Connection Failed" "$alert_msg"
  
  exit 1
fi

echo "✓ Connected successfully"
echo ""

# Get Redis INFO
info_output=$("${REDIS_CMD[@]}" INFO 2>/dev/null || echo "")

if [[ -z "$info_output" ]]; then
  echo "Failed to retrieve Redis INFO"
  exit 1
fi

# Parse key metrics
redis_version=$(echo "$info_output" | grep "^redis_version:" | cut -d: -f2 | tr -d '\r')
uptime_days=$(echo "$info_output" | grep "^uptime_in_days:" | cut -d: -f2 | tr -d '\r')
connected_clients=$(echo "$info_output" | grep "^connected_clients:" | cut -d: -f2 | tr -d '\r')
used_memory=$(echo "$info_output" | grep "^used_memory:" | cut -d: -f2 | tr -d '\r')
used_memory_human=$(echo "$info_output" | grep "^used_memory_human:" | cut -d: -f2 | tr -d '\r')
maxmemory=$(echo "$info_output" | grep "^maxmemory:" | cut -d: -f2 | tr -d '\r')
total_commands=$(echo "$info_output" | grep "^total_commands_processed:" | cut -d: -f2 | tr -d '\r')
instantaneous_ops=$(echo "$info_output" | grep "^instantaneous_ops_per_sec:" | cut -d: -f2 | tr -d '\r')
keyspace_hits=$(echo "$info_output" | grep "^keyspace_hits:" | cut -d: -f2 | tr -d '\r')
keyspace_misses=$(echo "$info_output" | grep "^keyspace_misses:" | cut -d: -f2 | tr -d '\r')
evicted_keys=$(echo "$info_output" | grep "^evicted_keys:" | cut -d: -f2 | tr -d '\r')
expired_keys=$(echo "$info_output" | grep "^expired_keys:" | cut -d: -f2 | tr -d '\r')
role=$(echo "$info_output" | grep "^role:" | cut -d: -f2 | tr -d '\r')

echo "=== Redis Server Info ==="
echo "Version: $redis_version"
echo "Uptime: $uptime_days days"
echo "Role: $role"
echo ""

echo "=== Performance Metrics ==="
echo "Connected clients: $connected_clients"
echo "Operations/sec: $instantaneous_ops"
echo "Total commands: $total_commands"
echo "Used memory: $used_memory_human"
echo "Evicted keys: $evicted_keys"
echo "Expired keys: $expired_keys"
echo ""

# Calculate cache hit ratio
if [[ -n "$keyspace_hits" && -n "$keyspace_misses" && $keyspace_hits -gt 0 ]]; then
  total_requests=$((keyspace_hits + keyspace_misses))
  hit_ratio=$(echo "scale=2; $keyspace_hits * 100 / $total_requests" | bc -l 2>/dev/null || echo "0")
  echo "Cache hit ratio: ${hit_ratio}%"
  echo ""
fi

# Check for alerts
declare -i alert_count=0

# Check memory usage
if [[ -n "$maxmemory" && $maxmemory -gt 0 ]]; then
  memory_pct=$(echo "scale=2; $used_memory * 100 / $maxmemory" | bc -l 2>/dev/null || echo "0")
  memory_pct_int=${memory_pct%.*}
  
  echo "Memory usage: ${memory_pct}%"
  
  if [[ ${memory_pct_int:-0} -gt $MEMORY_THRESHOLD ]]; then
    echo "⚠️  ALERT: Memory usage (${memory_pct}%) exceeds threshold (${MEMORY_THRESHOLD}%)"
    ((alert_count++))
    
    alert_msg="⚠️ Redis Alert: High memory usage\nHost: $HOST:$PORT\nUsed: $used_memory_human (${memory_pct}%)\nThreshold: ${MEMORY_THRESHOLD}%"
    send_slack_alert "$alert_msg"
    send_email_alert "Redis: High Memory Usage" "$alert_msg"
  fi
fi

# Check connected clients
if [[ ${connected_clients:-0} -gt $CLIENTS_THRESHOLD ]]; then
  echo "⚠️  ALERT: Connected clients ($connected_clients) exceeds threshold ($CLIENTS_THRESHOLD)"
  ((alert_count++))
  
  alert_msg="⚠️ Redis Alert: High client connections\nHost: $HOST:$PORT\nClients: $connected_clients\nThreshold: $CLIENTS_THRESHOLD"
  send_slack_alert "$alert_msg"
  send_email_alert "Redis: High Client Connections" "$alert_msg"
fi

# Check operations per second
if [[ ${instantaneous_ops:-0} -gt $OPS_THRESHOLD ]]; then
  echo "⚠️  ALERT: Operations/sec ($instantaneous_ops) exceeds threshold ($OPS_THRESHOLD)"
  ((alert_count++))
  
  alert_msg="⚠️ Redis Alert: High operations rate\nHost: $HOST:$PORT\nOps/sec: $instantaneous_ops\nThreshold: $OPS_THRESHOLD"
  send_slack_alert "$alert_msg"
  send_email_alert "Redis: High Operations Rate" "$alert_msg"
fi

# Check for replication lag (if slave)
if [[ "$role" == "slave" ]]; then
  master_link_status=$(echo "$info_output" | grep "^master_link_status:" | cut -d: -f2 | tr -d '\r')
  
  if [[ "$master_link_status" != "up" ]]; then
    echo "⚠️  ALERT: Replication link is DOWN"
    ((alert_count++))
    
    alert_msg="🔴 Redis Alert: Replication link down\nHost: $HOST:$PORT\nStatus: $master_link_status"
    send_slack_alert "$alert_msg"
    send_email_alert "Redis: Replication Link Down" "$alert_msg"
  fi
fi

# Check for high eviction rate
if [[ ${evicted_keys:-0} -gt 1000 ]]; then
  echo "⚠️  WARNING: High evicted keys count ($evicted_keys) - consider increasing maxmemory"
fi

# Get database keyspace info
echo ""
echo "=== Keyspace Info ==="
keyspace=$(echo "$info_output" | grep "^db[0-9]" || echo "")
if [[ -n "$keyspace" ]]; then
  echo "$keyspace"
else
  echo "No databases with keys"
fi

echo ""
echo "=== Summary ==="
echo "Alerts triggered: $alert_count"

if [[ $alert_count -gt 0 ]]; then
  echo "⚠️  Redis health issues detected!"
  exit 1
else
  echo "✓ Redis health OK"
  exit 0
fi
