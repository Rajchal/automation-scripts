#!/usr/bin/env bash
set -euo pipefail

# elasticsearch-cluster-monitor.sh
# Monitor Elasticsearch cluster health, node status, and index metrics.
# Checks cluster status, shard allocation, disk usage, and JVM memory.
# Dry-run by default; use --no-dry-run to enable monitoring.

usage(){
  cat <<EOF
Usage: $0 [--host HOST] [--port PORT] [--user USER] [--password PASS] [--disk-threshold PCT] [--no-dry-run]

Options:
  --host HOST              Elasticsearch host (default: localhost)
  --port PORT              Elasticsearch port (default: 9200)
  --user USER              Elasticsearch username (optional)
  --password PASS          Elasticsearch password (optional)
  --disk-threshold PCT     Alert if disk usage > N% (default: 85)
  --heap-threshold PCT     Alert if JVM heap > N% (default: 90)
  --unassigned-shards N    Alert if unassigned shards > N (default: 0)
  --slack-webhook URL      Slack webhook URL for alerts
  --email TO               Email address for alerts
  --no-dry-run             Enable monitoring (default: dry-run)
  -h, --help               Show this help

Examples:
  # Dry-run: show what would be monitored
  bash/elasticsearch-cluster-monitor.sh

  # Monitor local Elasticsearch cluster
  bash/elasticsearch-cluster-monitor.sh --host localhost --port 9200 --no-dry-run

  # Monitor with authentication and custom thresholds
  bash/elasticsearch-cluster-monitor.sh \\
    --host es.example.com \\
    --port 9200 \\
    --user elastic \\
    --password secret123 \\
    --disk-threshold 80 \\
    --heap-threshold 85 \\
    --slack-webhook https://hooks.slack.com/... \\
    --no-dry-run

  # Cron job to check every 10 minutes
  */10 * * * * /path/to/elasticsearch-cluster-monitor.sh --host es-prod --user elastic --password PASS --no-dry-run

EOF
}

HOST="localhost"
PORT=9200
USER=""
PASSWORD=""
DISK_THRESHOLD=85
HEAP_THRESHOLD=90
UNASSIGNED_SHARDS_THRESHOLD=0
SLACK_WEBHOOK=""
EMAIL=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --user) USER="$2"; shift 2;;
    --password) PASSWORD="$2"; shift 2;;
    --disk-threshold) DISK_THRESHOLD="$2"; shift 2;;
    --heap-threshold) HEAP_THRESHOLD="$2"; shift 2;;
    --unassigned-shards) UNASSIGNED_SHARDS_THRESHOLD="$2"; shift 2;;
    --slack-webhook) SLACK_WEBHOOK="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "curl required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required"; exit 3
fi

echo "Elasticsearch Cluster Monitor: host=$HOST:$PORT disk-threshold=${DISK_THRESHOLD}% dry-run=$DRY_RUN"

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: would monitor Elasticsearch cluster health"
  exit 0
fi

# Build auth parameter
AUTH=""
if [[ -n "$USER" && -n "$PASSWORD" ]]; then
  AUTH="-u $USER:$PASSWORD"
fi

ES_URL="http://$HOST:$PORT"

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
echo "Testing Elasticsearch connection..."
version_info=$(curl -s $AUTH "$ES_URL" 2>/dev/null || echo '{}')

if [[ "$(echo "$version_info" | jq -r '.version.number // ""')" == "" ]]; then
  echo "❌ Failed to connect to Elasticsearch at $HOST:$PORT"
  
  alert_msg="🔴 Elasticsearch Alert: Cannot connect to cluster\nHost: $HOST:$PORT"
  send_slack_alert "$alert_msg"
  send_email_alert "Elasticsearch: Connection Failed" "$alert_msg"
  
  exit 1
fi

es_version=$(echo "$version_info" | jq -r '.version.number')
cluster_name=$(echo "$version_info" | jq -r '.cluster_name')

echo "✓ Connected successfully"
echo "Cluster: $cluster_name"
echo "Version: $es_version"
echo ""

declare -i alert_count=0

# Get cluster health
echo "=== Cluster Health ==="
health=$(curl -s $AUTH "$ES_URL/_cluster/health" 2>/dev/null || echo '{}')

status=$(echo "$health" | jq -r '.status')
num_nodes=$(echo "$health" | jq -r '.number_of_nodes')
num_data_nodes=$(echo "$health" | jq -r '.number_of_data_nodes')
active_shards=$(echo "$health" | jq -r '.active_shards')
relocating_shards=$(echo "$health" | jq -r '.relocating_shards')
initializing_shards=$(echo "$health" | jq -r '.initializing_shards')
unassigned_shards=$(echo "$health" | jq -r '.unassigned_shards')

case "$status" in
  green) status_icon="🟢";;
  yellow) status_icon="🟡";;
  red) status_icon="🔴";;
  *) status_icon="❓";;
esac

echo "$status_icon Status: $status"
echo "Nodes: $num_nodes (data: $num_data_nodes)"
echo "Active shards: $active_shards"
echo "Relocating shards: $relocating_shards"
echo "Initializing shards: $initializing_shards"
echo "Unassigned shards: $unassigned_shards"
echo ""

# Alert on cluster status
if [[ "$status" == "red" ]]; then
  echo "🔴 ALERT: Cluster status is RED"
  ((alert_count++))
  
  alert_msg="🔴 Elasticsearch Alert: Cluster status RED\nCluster: $cluster_name\nHost: $HOST:$PORT\nUnassigned shards: $unassigned_shards"
  send_slack_alert "$alert_msg"
  send_email_alert "Elasticsearch: Cluster Status RED" "$alert_msg"
elif [[ "$status" == "yellow" ]]; then
  echo "🟡 WARNING: Cluster status is YELLOW"
fi

# Alert on unassigned shards
if [[ ${unassigned_shards:-0} -gt $UNASSIGNED_SHARDS_THRESHOLD ]]; then
  echo "⚠️  ALERT: Unassigned shards ($unassigned_shards) exceeds threshold ($UNASSIGNED_SHARDS_THRESHOLD)"
  ((alert_count++))
  
  alert_msg="⚠️ Elasticsearch Alert: Unassigned shards detected\nCluster: $cluster_name\nUnassigned: $unassigned_shards\nThreshold: $UNASSIGNED_SHARDS_THRESHOLD"
  send_slack_alert "$alert_msg"
  send_email_alert "Elasticsearch: Unassigned Shards" "$alert_msg"
fi

# Get node stats
echo "=== Node Stats ==="
nodes=$(curl -s $AUTH "$ES_URL/_nodes/stats/jvm,fs" 2>/dev/null || echo '{"nodes":{}}')

mapfile -t node_ids < <(echo "$nodes" | jq -r '.nodes | keys[]')

for node_id in "${node_ids[@]}"; do
  node_name=$(echo "$nodes" | jq -r ".nodes[\"$node_id\"].name")
  
  # JVM heap
  heap_used_pct=$(echo "$nodes" | jq -r ".nodes[\"$node_id\"].jvm.mem.heap_used_percent")
  heap_used=$(echo "$nodes" | jq -r ".nodes[\"$node_id\"].jvm.mem.heap_used")
  heap_max=$(echo "$nodes" | jq -r ".nodes[\"$node_id\"].jvm.mem.heap_max")
  
  # Disk usage
  disk_total=$(echo "$nodes" | jq -r ".nodes[\"$node_id\"].fs.total.total_in_bytes")
  disk_available=$(echo "$nodes" | jq -r ".nodes[\"$node_id\"].fs.total.available_in_bytes")
  
  if [[ "$disk_total" != "null" && $disk_total -gt 0 ]]; then
    disk_used=$((disk_total - disk_available))
    disk_used_pct=$(echo "scale=2; $disk_used * 100 / $disk_total" | bc -l 2>/dev/null || echo "0")
    disk_used_pct_int=${disk_used_pct%.*}
  else
    disk_used_pct="N/A"
    disk_used_pct_int=0
  fi
  
  echo "Node: $node_name"
  echo "  JVM Heap: ${heap_used_pct}%"
  echo "  Disk Usage: ${disk_used_pct}%"
  
  # Alert on high heap usage
  if [[ ${heap_used_pct:-0} -gt $HEAP_THRESHOLD ]]; then
    echo "  ⚠️  ALERT: High JVM heap usage (${heap_used_pct}%)"
    ((alert_count++))
    
    alert_msg="⚠️ Elasticsearch Alert: High JVM heap usage\nNode: $node_name\nCluster: $cluster_name\nHeap: ${heap_used_pct}%\nThreshold: ${HEAP_THRESHOLD}%"
    send_slack_alert "$alert_msg"
    send_email_alert "Elasticsearch: High JVM Heap" "$alert_msg"
  fi
  
  # Alert on high disk usage
  if [[ ${disk_used_pct_int:-0} -gt $DISK_THRESHOLD ]]; then
    echo "  ⚠️  ALERT: High disk usage (${disk_used_pct}%)"
    ((alert_count++))
    
    alert_msg="⚠️ Elasticsearch Alert: High disk usage\nNode: $node_name\nCluster: $cluster_name\nDisk: ${disk_used_pct}%\nThreshold: ${DISK_THRESHOLD}%"
    send_slack_alert "$alert_msg"
    send_email_alert "Elasticsearch: High Disk Usage" "$alert_msg"
  fi
  
  echo ""
done

# Get index stats (top 10 largest indices)
echo "=== Largest Indices ==="
indices=$(curl -s $AUTH "$ES_URL/_cat/indices?v&h=index,docs.count,store.size&s=store.size:desc" 2>/dev/null | tail -n +2 | head -10)
echo "$indices"
echo ""

# Check for pending tasks
echo "=== Pending Tasks ==="
pending=$(curl -s $AUTH "$ES_URL/_cluster/pending_tasks" 2>/dev/null || echo '{"tasks":[]}')
pending_count=$(echo "$pending" | jq '.tasks | length')

if [[ ${pending_count:-0} -gt 0 ]]; then
  echo "⚠️  WARNING: $pending_count pending cluster tasks"
  echo "$pending" | jq -r '.tasks[] | "  - \(.priority): \(.source)"' | head -5
else
  echo "✓ No pending tasks"
fi

echo ""
echo "=== Summary ==="
echo "Cluster status: $status_icon $status"
echo "Alerts triggered: $alert_count"

if [[ $alert_count -gt 0 || "$status" == "red" ]]; then
  echo "⚠️  Elasticsearch cluster has issues!"
  exit 1
else
  echo "✓ Elasticsearch cluster health OK"
  exit 0
fi
