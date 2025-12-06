#!/usr/bin/env bash
set -euo pipefail

# jenkins-build-monitor.sh
# Monitor Jenkins build jobs and alert on failures or stuck builds.
# Supports multiple Jenkins servers and Slack/email notifications.
# Dry-run by default; use --no-dry-run to enable monitoring.

usage(){
  cat <<EOF
Usage: $0 --jenkins-url URL [--job NAME] [--user USER] [--token TOKEN] [--slack-webhook URL] [--no-dry-run]

Options:
  --jenkins-url URL        Jenkins server URL (required)
  --job NAME               Specific job to monitor (default: all jobs)
  --user USER              Jenkins username for authentication
  --token TOKEN            Jenkins API token
  --slack-webhook URL      Slack webhook URL for alerts
  --email TO               Email address for alerts
  --stuck-threshold MIN    Alert if build runs longer than N minutes (default: 60)
  --no-dry-run             Enable monitoring (default: dry-run)
  -h, --help               Show this help

Examples:
  # Dry-run: show what would be monitored
  bash/jenkins-build-monitor.sh --jenkins-url http://jenkins.example.com:8080

  # Monitor all jobs with authentication
  bash/jenkins-build-monitor.sh --jenkins-url http://jenkins.example.com:8080 --user admin --token abc123 --no-dry-run

  # Monitor specific job and send Slack alerts
  bash/jenkins-build-monitor.sh --jenkins-url http://jenkins.example.com:8080 --job production-deploy --slack-webhook https://hooks.slack.com/... --no-dry-run

  # Cron job to check every 5 minutes
  */5 * * * * /path/to/jenkins-build-monitor.sh --jenkins-url http://jenkins.example.com --user admin --token TOKEN --slack-webhook URL --no-dry-run

EOF
}

JENKINS_URL=""
JOB_NAME=""
USER=""
TOKEN=""
SLACK_WEBHOOK=""
EMAIL=""
STUCK_THRESHOLD=60
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jenkins-url) JENKINS_URL="$2"; shift 2;;
    --job) JOB_NAME="$2"; shift 2;;
    --user) USER="$2"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    --slack-webhook) SLACK_WEBHOOK="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --stuck-threshold) STUCK_THRESHOLD="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$JENKINS_URL" ]]; then
  echo "--jenkins-url is required"; usage; exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required"; exit 3
fi

# Remove trailing slash from Jenkins URL
JENKINS_URL="${JENKINS_URL%/}"

# Build auth parameter
AUTH=""
if [[ -n "$USER" && -n "$TOKEN" ]]; then
  AUTH="-u $USER:$TOKEN"
fi

echo "Jenkins Build Monitor: url=$JENKINS_URL job=${JOB_NAME:-all} dry-run=$DRY_RUN"

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: would monitor Jenkins builds and send alerts"
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

# Get jobs to monitor
if [[ -n "$JOB_NAME" ]]; then
  jobs=("$JOB_NAME")
else
  echo "Fetching job list..."
  jobs_json=$(curl -s $AUTH "$JENKINS_URL/api/json?tree=jobs[name]" 2>/dev/null || echo '{"jobs":[]}')
  mapfile -t jobs < <(echo "$jobs_json" | jq -r '.jobs[]?.name' | grep -v null)
fi

if [[ ${#jobs[@]} -eq 0 ]]; then
  echo "No jobs found"
  exit 0
fi

echo "Monitoring ${#jobs[@]} job(s)"
echo ""

declare -i failed_count=0
declare -i stuck_count=0
now_epoch=$(date +%s)

for job in "${jobs[@]}"; do
  # URL encode job name
  encoded_job=$(printf %s "$job" | jq -sRr @uri)
  
  # Get job info
  job_json=$(curl -s $AUTH "$JENKINS_URL/job/$encoded_job/api/json?tree=lastBuild[number,result,timestamp,duration,building,url],lastSuccessfulBuild[number],lastFailedBuild[number]" 2>/dev/null || echo '{}')
  
  last_build=$(echo "$job_json" | jq -r '.lastBuild // empty')
  
  if [[ -z "$last_build" || "$last_build" == "null" ]]; then
    continue
  fi
  
  build_number=$(echo "$last_build" | jq -r '.number // "N/A"')
  result=$(echo "$last_build" | jq -r '.result // "UNKNOWN"')
  building=$(echo "$last_build" | jq -r '.building // false')
  timestamp=$(echo "$last_build" | jq -r '.timestamp // 0')
  duration=$(echo "$last_build" | jq -r '.duration // 0')
  build_url=$(echo "$last_build" | jq -r '.url // ""')
  
  # Convert timestamp from milliseconds
  build_epoch=$((timestamp / 1000))
  
  # Check if build is currently running
  if [[ "$building" == "true" ]]; then
    running_minutes=$(( (now_epoch - build_epoch) / 60 ))
    
    if [[ $running_minutes -gt $STUCK_THRESHOLD ]]; then
      echo "⚠️  STUCK: $job #$build_number (running for ${running_minutes}m)"
      ((stuck_count++))
      
      alert_msg="⚠️ Jenkins Alert: Job '$job' #$build_number has been running for ${running_minutes} minutes (threshold: ${STUCK_THRESHOLD}m)\nURL: $build_url"
      send_slack_alert "$alert_msg"
      send_email_alert "Jenkins: Stuck Build - $job" "$alert_msg"
    else
      echo "🔄 BUILDING: $job #$build_number (${running_minutes}m)"
    fi
  elif [[ "$result" == "FAILURE" || "$result" == "ABORTED" || "$result" == "UNSTABLE" ]]; then
    age_minutes=$(( (now_epoch - build_epoch) / 60 ))
    
    # Only alert on recent failures (within last 10 minutes)
    if [[ $age_minutes -lt 10 ]]; then
      echo "❌ FAILED: $job #$build_number (result: $result, ${age_minutes}m ago)"
      ((failed_count++))
      
      alert_msg="❌ Jenkins Alert: Job '$job' #$build_number $result\nURL: $build_url"
      send_slack_alert "$alert_msg"
      send_email_alert "Jenkins: Build Failure - $job" "$alert_msg"
    else
      echo "❌ FAILED: $job #$build_number (result: $result, ${age_minutes}m ago) [not alerting]"
    fi
  elif [[ "$result" == "SUCCESS" ]]; then
    echo "✓ SUCCESS: $job #$build_number"
  else
    echo "? UNKNOWN: $job #$build_number (result: $result)"
  fi
done

echo ""
echo "=== Summary ==="
echo "Failed builds (recent): $failed_count"
echo "Stuck builds: $stuck_count"

if [[ $failed_count -gt 0 || $stuck_count -gt 0 ]]; then
  exit 1
else
  echo "✓ All monitored builds OK"
  exit 0
fi
