#!/usr/bin/env bash
set -euo pipefail

# nginx-access-log-monitor.sh
# Monitor Nginx access logs for suspicious activity, DDoS patterns, and anomalies.
# Detects high request rates, 404 scanning, SQL injection attempts, and more.
# Dry-run by default; use --no-dry-run to enable monitoring.

usage(){
  cat <<EOF
Usage: $0 [--log-file PATH] [--threshold REQUESTS] [--time-window SECONDS] [--block-ip] [--no-dry-run]

Options:
  --log-file PATH          Path to Nginx access log (default: /var/log/nginx/access.log)
  --threshold REQUESTS     Alert if IP makes > N requests in time window (default: 100)
  --time-window SECONDS    Time window for rate limiting (default: 60)
  --block-ip               Auto-block suspicious IPs using iptables (requires root)
  --whitelist-file PATH    File containing whitelisted IPs (one per line)
  --slack-webhook URL      Slack webhook URL for alerts
  --no-dry-run             Enable monitoring (default: dry-run)
  -h, --help               Show this help

Examples:
  # Dry-run: show what would be monitored
  bash/nginx-access-log-monitor.sh

  # Monitor with custom threshold (200 requests/minute)
  bash/nginx-access-log-monitor.sh --threshold 200 --no-dry-run

  # Monitor and auto-block suspicious IPs
  sudo bash/nginx-access-log-monitor.sh --threshold 100 --block-ip --no-dry-run

  # Monitor with Slack alerts
  bash/nginx-access-log-monitor.sh --threshold 150 --slack-webhook https://hooks.slack.com/... --no-dry-run

  # Continuous monitoring via tail (run in background)
  bash/nginx-access-log-monitor.sh --threshold 100 --no-dry-run &

EOF
}

LOG_FILE="/var/log/nginx/access.log"
THRESHOLD=100
TIME_WINDOW=60
BLOCK_IP=false
WHITELIST_FILE=""
SLACK_WEBHOOK=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log-file) LOG_FILE="$2"; shift 2;;
    --threshold) THRESHOLD="$2"; shift 2;;
    --time-window) TIME_WINDOW="$2"; shift 2;;
    --block-ip) BLOCK_IP=true; shift;;
    --whitelist-file) WHITELIST_FILE="$2"; shift 2;;
    --slack-webhook) SLACK_WEBHOOK="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ ! -f "$LOG_FILE" ]]; then
  echo "Log file not found: $LOG_FILE"
  exit 1
fi

echo "Nginx Access Log Monitor: log=$LOG_FILE threshold=$THRESHOLD/$TIME_WINDOW"s block-ip=$BLOCK_IP dry-run=$DRY_RUN"

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: would monitor Nginx access logs for suspicious activity"
  exit 0
fi

# Load whitelist if provided
declare -A whitelist
if [[ -n "$WHITELIST_FILE" && -f "$WHITELIST_FILE" ]]; then
  while read -r ip; do
    [[ -n "$ip" && ! "$ip" =~ ^# ]] && whitelist["$ip"]=1
  done < "$WHITELIST_FILE"
  echo "Loaded ${#whitelist[@]} whitelisted IP(s)"
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

# Function to block IP with iptables
block_ip() {
  local ip="$1"
  
  if [[ "$BLOCK_IP" == true ]]; then
    if command -v iptables >/dev/null 2>&1; then
      echo "Blocking IP: $ip"
      iptables -I INPUT -s "$ip" -j DROP 2>/dev/null || echo "Failed to block $ip (requires root)"
    else
      echo "iptables not available, cannot block IP"
    fi
  fi
}

# Temporary file to track IP request counts
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

declare -A ip_counts
declare -A ip_404_counts
declare -A suspicious_patterns

echo "Starting monitoring... (Press Ctrl+C to stop)"
echo ""

# Analyze recent log entries
cutoff_time=$(($(date +%s) - TIME_WINDOW))

# Parse log file (last N lines for recent activity)
tail -n 10000 "$LOG_FILE" | while IFS= read -r line; do
  # Parse common Nginx log format: IP - - [timestamp] "METHOD /path HTTP/1.1" status size
  if [[ "$line" =~ ^([0-9.]+)\ -\ -\ \[([^\]]+)\]\ \"([A-Z]+)\ ([^\"]+)\ HTTP/[0-9.]+\"\ ([0-9]+)\ ([0-9]+) ]]; then
    ip="${BASH_REMATCH[1]}"
    timestamp="${BASH_REMATCH[2]}"
    method="${BASH_REMATCH[3]}"
    path="${BASH_REMATCH[4]}"
    status="${BASH_REMATCH[5]}"
    size="${BASH_REMATCH[6]}"
    
    # Skip whitelisted IPs
    [[ -n "${whitelist[$ip]:-}" ]] && continue
    
    # Convert timestamp to epoch (simplified - may need adjustment for your log format)
    # Example: 07/Dec/2025:10:30:45 +0000
    log_epoch=$(date -d "$(echo "$timestamp" | sed 's/:/ /' | cut -d' ' -f1-2)" +%s 2>/dev/null || echo 0)
    
    # Only process recent entries
    [[ $log_epoch -lt $cutoff_time ]] && continue
    
    # Count requests per IP
    ((ip_counts[$ip]++)) || ip_counts[$ip]=1
    
    # Track 404 errors (potential scanning)
    if [[ "$status" == "404" ]]; then
      ((ip_404_counts[$ip]++)) || ip_404_counts[$ip]=1
    fi
    
    # Detect suspicious patterns
    if [[ "$path" =~ (union.*select|\.\.\/|\/etc\/passwd|\.php\?|eval\(|base64_decode|<script|javascript:|onload=) ]]; then
      suspicious_patterns[$ip]="${suspicious_patterns[$ip]:-}; $path"
    fi
  fi
done

# Analyze collected data
echo "=== Analysis Results ==="
echo ""

declare -i alert_count=0

# Check for high request rates
echo "High Request Rate IPs:"
for ip in "${!ip_counts[@]}"; do
  count="${ip_counts[$ip]}"
  
  if [[ $count -gt $THRESHOLD ]]; then
    echo "  🔴 $ip: $count requests in ${TIME_WINDOW}s"
    ((alert_count++))
    
    alert_msg="⚠️ Nginx Alert: High request rate from $ip\nRequests: $count in ${TIME_WINDOW}s (threshold: $THRESHOLD)\nLog: $LOG_FILE"
    send_slack_alert "$alert_msg"
    block_ip "$ip"
  fi
done
echo ""

# Check for 404 scanning
echo "404 Scanning Activity:"
for ip in "${!ip_404_counts[@]}"; do
  count="${ip_404_counts[$ip]}"
  
  if [[ $count -gt 20 ]]; then
    echo "  🟡 $ip: $count 404 errors (possible scanning)"
    ((alert_count++))
    
    alert_msg="⚠️ Nginx Alert: 404 scanning detected from $ip\n404 errors: $count\nLog: $LOG_FILE"
    send_slack_alert "$alert_msg"
  fi
done
echo ""

# Check for suspicious patterns
if [[ ${#suspicious_patterns[@]} -gt 0 ]]; then
  echo "Suspicious Patterns Detected:"
  for ip in "${!suspicious_patterns[@]}"; do
    patterns="${suspicious_patterns[$ip]}"
    echo "  🔴 $ip: Potential attack"
    echo "     Patterns: ${patterns:0:200}"
    ((alert_count++))
    
    alert_msg="🚨 Nginx Alert: Suspicious activity from $ip\nPatterns detected: ${patterns:0:100}\nLog: $LOG_FILE"
    send_slack_alert "$alert_msg"
    block_ip "$ip"
  done
  echo ""
fi

# Top requesters summary
echo "=== Top 10 Requesters ==="
for ip in "${!ip_counts[@]}"; do
  echo "${ip_counts[$ip]} $ip"
done | sort -rn | head -10

echo ""
echo "=== Summary ==="
echo "Total unique IPs: ${#ip_counts[@]}"
echo "Alerts triggered: $alert_count"

if [[ $alert_count -gt 0 ]]; then
  echo "⚠️ Suspicious activity detected!"
  exit 1
else
  echo "✓ No suspicious activity detected"
  exit 0
fi
