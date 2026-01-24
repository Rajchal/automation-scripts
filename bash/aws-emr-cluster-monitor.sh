#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
HOURS_THRESHOLD="${HOURS_THRESHOLD:-24}"
TMP_REPORT="/tmp/aws-emr-cluster-monitor-$(date +%s).txt"

log_message() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"
}

jq_safe() {
  echo "$1" | jq -r "$2" 2>/dev/null || echo ""
}

write_header() {
  echo "EMR cluster monitor run: $(date -u)" > "$TMP_REPORT"
}

send_slack_alert() {
  if [ -z "$SLACK_WEBHOOK" ]; then
    return 0
  fi
  payload=$(jq -n --arg text "$1" '{"text":$text}')
  curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" >/dev/null || true
}

main() {
  write_header
  log_message "Checking EMR clusters in region $REGION"

  cluster_ids_json=$(aws emr list-clusters --region "$REGION" --cluster-states RUNNING WAITING --query 'Clusters[].Id' --output json 2>/dev/null || echo "[]")
  if [ "$cluster_ids_json" = "[]" ]; then
    log_message "No RUNNING or WAITING clusters found"
    exit 0
  fi

  now=$(date +%s)
  alerts=()

  for id in $(echo "$cluster_ids_json" | jq -r '.[]'); do
    desc=$(aws emr describe-cluster --region "$REGION" --cluster-id "$id" --output json 2>/dev/null || echo "{}")
    state=$(echo "$desc" | jq -r '.Cluster.Status.State // empty')
    name=$(echo "$desc" | jq -r '.Cluster.Name // empty')
    created=$(echo "$desc" | jq -r '.Cluster.Status.Timeline.CreationDateTime // empty')
    if [ -z "$created" ] || [ "$created" = "null" ]; then
      continue
    fi

    # convert creation time to epoch
    created_ts=$(date -d "$created" +%s 2>/dev/null || echo 0)
    if [ "$created_ts" -eq 0 ]; then
      continue
    fi
    age_hours=$(( (now - created_ts) / 3600 ))

    steps_count=$(aws emr list-steps --region "$REGION" --cluster-id "$id" --query 'length(Steps)' --output text 2>/dev/null || echo 0)
    steps_count=${steps_count:-0}

    if { [ "$state" = "WAITING" ] || [ "$state" = "RUNNING" ]; } && [ "$steps_count" -eq 0 ] && [ "$age_hours" -ge "$HOURS_THRESHOLD" ]; then
      msg="Cluster $id ($name) is $state, ${age_hours}h old, steps: ${steps_count}"
      alerts+=("$msg")
      echo "$msg" >> "$TMP_REPORT"
    fi
  done

  if [ "${#alerts[@]}" -gt 0 ]; then
    body="EMR clusters without steps older than ${HOURS_THRESHOLD}h:\n$(printf '%s\n' "${alerts[@]}")"
    send_slack_alert "$body"
    log_message "Found ${#alerts[@]} clusters requiring attention; Slack alert sent (if configured)"
    exit 2
  else
    log_message "No problematic EMR clusters found"
    exit 0
  fi
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
HOURS_OLD="${HOURS_OLD:-24}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
PROFILE_OPT=""
if [[ -n "${AWS_PROFILE:-}" ]]; then
  PROFILE_OPT="--profile ${AWS_PROFILE}"
fi

LOG_FILE="/var/log/aws-emr-cluster-monitor.log"
REPORT_FILE="/tmp/emr-cluster-monitor-$(date +%Y%m%d%H%M%S).txt"
NOW_TS=$(date +%s)

log_message() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

jq_safe() {
  local data="$1" query="$2"
  echo "$data" | jq -r "$query" 2>/dev/null || echo ""
}

write_header() {
  echo "EMR Cluster Monitor Report - $(date '+%Y-%m-%d %H:%M:%S')" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Threshold (hours): $HOURS_OLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

send_slack_alert() {
  local msg="$1"
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -s -X POST -H 'Content-type: application/json' --data "{\"text\": \"${msg//\"/\\\"}\"}" "$SLACK_WEBHOOK" >/dev/null || true
  fi
}

check_dependencies() {
  command -v aws >/dev/null 2>&1 || { echo "aws CLI not found in PATH" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "jq not found in PATH" >&2; exit 2; }
  command -v curl >/dev/null 2>&1 || { echo "curl not found in PATH" >&2; exit 2; }
}

main() {
  check_dependencies
  write_header

  clusters_json=$(aws emr list-clusters $PROFILE_OPT --region "$REGION" --cluster-states RUNNING WAITING --output json 2>/dev/null || echo '{}')
  if [[ -z "$(echo "$clusters_json" | jq -r '.Clusters | length')" || "$(echo "$clusters_json" | jq -r '.Clusters | length')" == "0" ]]; then
    log_message "No RUNNING or WAITING EMR clusters found in $REGION"
    echo "No RUNNING or WAITING EMR clusters found." >> "$REPORT_FILE"
    exit 0
  fi

  found=0
  echo "Clusters checked:" >> "$REPORT_FILE"
  echo "-----------------" >> "$REPORT_FILE"

  echo "$clusters_json" | jq -c '.Clusters[]' | while read -r cluster; do
    id=$(jq -r '.Id' <<<"$cluster")
    name=$(jq -r '.Name' <<<"$cluster")

    desc_json=$(aws emr describe-cluster $PROFILE_OPT --cluster-id "$id" --region "$REGION" --output json 2>/dev/null || echo '{}')
    state=$(jq -r '.Cluster.Status.State' <<<"$desc_json" 2>/dev/null || echo 'UNKNOWN')
    creation=$(jq -r '.Cluster.Status.Timeline.CreationDateTime' <<<"$desc_json" 2>/dev/null || echo '')
    if [[ -z "$creation" || "$creation" == "null" ]]; then
      created_ts=0
      age_hours=0
    else
      created_ts=$(date -d "$creation" +%s)
      age_hours=$(( (NOW_TS - created_ts) / 3600 ))
    fi

    steps_json=$(aws emr list-steps $PROFILE_OPT --cluster-id "$id" --region "$REGION" --output json 2>/dev/null || echo '{}')
    steps_count=$(jq -r '.Steps | length' <<<"$steps_json" 2>/dev/null || echo '0')

    note=""
    if [[ "$state" == "WAITING" || "$state" == "RUNNING" ]]; then
      if [[ "$steps_count" -eq 0 ]]; then
        note="No steps found"
      fi
      if [[ "$age_hours" -ge "$HOURS_OLD" ]]; then
        if [[ -n "$note" ]]; then
          note="$note; Older than ${HOURS_OLD}h (age=${age_hours}h)"
        else
          note="Older than ${HOURS_OLD}h (age=${age_hours}h)"
        fi
      fi
    fi

    if [[ -n "$note" ]]; then
      found=1
      echo "- ClusterId: $id" >> "$REPORT_FILE"
      echo "  Name: $name" >> "$REPORT_FILE"
      echo "  State: $state" >> "$REPORT_FILE"
      echo "  AgeHours: ${age_hours}" >> "$REPORT_FILE"
      echo "  StepsCount: ${steps_count}" >> "$REPORT_FILE"
      echo "  Note: $note" >> "$REPORT_FILE"
      echo "" >> "$REPORT_FILE"
      log_message "Issue found for EMR cluster $id ($name): $note"
    else
      echo "- $id ($name): OK (state=$state, steps=$steps_count, age=${age_hours}h)" >> "$REPORT_FILE"
    fi
  done

  if [[ "$found" -ne 0 ]]; then
    alert_msg="EMR monitor: issues found; see $REPORT_FILE"
    send_slack_alert "$alert_msg"
    log_message "$alert_msg"
    cat "$REPORT_FILE"
    exit 0
  else
    log_message "EMR monitor: no problematic clusters found"
    echo "No problematic EMR clusters found." >> "$REPORT_FILE"
    exit 0
  fi
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

# AWS EMR Cluster Monitor
# Checks for long-running or idle EMR clusters and optionally posts to Slack.

REGION="${AWS_REGION:-us-east-1}"
HOURS_THRESHOLD="${HOURS_THRESHOLD:-24}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
OUTPUT_FILE="/tmp/emr-cluster-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-emr-cluster-monitor.log}"

EMR=(aws emr --region "$REGION")
JQ=(jq -r)

log_message() {
  local level="$1"; shift
  local msg="$*"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$level] $msg" | tee -a "$LOG_FILE"
}

jq_safe() { jq -r "$@" 2>/dev/null || echo ""; }

send_slack_alert() {
  local title="$1"; shift
  local body="$*"
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -sS -X POST -H 'Content-type: application/json' --data "{\"text\":\"${title}: ${body}\"}" "$SLACK_WEBHOOK" >/dev/null || true
  fi
}

write_header() {
  echo "AWS EMR Cluster Monitor" > "$OUTPUT_FILE"
  echo "Region: $REGION" >> "$OUTPUT_FILE"
  echo "Threshold (hours): $HOURS_THRESHOLD" >> "$OUTPUT_FILE"
  echo "Generated: $(date -u)" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"
}

list_active_clusters() {
  ${EMR[*]} list-clusters --active --query 'Clusters[?State==`RUNNING` || State==`WAITING`].{Id:Id,Name:Name,State:State}' --output json 2>/dev/null || echo '[]'
}

describe_cluster() {
  local id="$1"
  ${EMR[*]} describe-cluster --cluster-id "$id" --output json 2>/dev/null || echo '{}'
}

list_steps() {
  local id="$1"
  ${EMR[*]} list-steps --cluster-id "$id" --query 'Steps[]' --output json 2>/dev/null || echo '[]'
}

iso_to_epoch() { date -d "$1" +%s 2>/dev/null || date -u +%s; }

check_clusters() {
  local now epoch_cutoff
  now=$(date -u +%s)
  epoch_cutoff=$((now - HOURS_THRESHOLD * 3600))

  local clusters
  clusters=$(list_active_clusters)
  if [[ -z "$clusters" || "$clusters" == "[]" ]]; then
    echo "No running/waiting EMR clusters found." >> "$OUTPUT_FILE"
    return
  fi

  echo "Clusters exceeding ${HOURS_THRESHOLD} hours or idle:" >> "$OUTPUT_FILE"
  echo "-----------------------------------------------" >> "$OUTPUT_FILE"

  local id name state
  local flagged=0

  while IFS= read -r row; do
    id=$(echo "$row" | ${JQ[0]} '.Id')
    name=$(echo "$row" | ${JQ[0]} '.Name')
    state=$(echo "$row" | ${JQ[0]} '.State')

    cluster_json=$(describe_cluster "$id")
    created=$(echo "$cluster_json" | jq -r '.Cluster.Status.Timeline.CreationDateTime' 2>/dev/null || echo "")
    created_epoch=$(iso_to_epoch "$created")
    if (( created_epoch <= epoch_cutoff )); then
      echo "- $id ($name) state=$state created=$created" >> "$OUTPUT_FILE"
      flagged=1
      log_message WARN "EMR cluster $id ($name) in $state for > ${HOURS_THRESHOLD}h"
    else
      steps=$(list_steps "$id")
      if [[ -z "$steps" || "$steps" == "[]" ]]; then
        echo "- $id ($name) state=$state : no steps found" >> "$OUTPUT_FILE"
        flagged=1
        log_message WARN "EMR cluster $id ($name) in $state with no steps"
      else
        last_step_time=$(echo "$steps" | jq -r '.[-1].StatusTimeline.EndDateTime // .[-1].StatusTimeline.CreationDateTime' 2>/dev/null || echo "")
        last_step_epoch=$(iso_to_epoch "$last_step_time")
        if (( last_step_epoch <= epoch_cutoff )); then
          echo "- $id ($name) state=$state : last step at $last_step_time" >> "$OUTPUT_FILE"
          flagged=1
          log_message WARN "EMR cluster $id ($name) idle since $last_step_time"
        fi
      fi
    fi
  done < <(echo "$clusters" | jq -c '.[]')

  if [[ $flagged -eq 0 ]]; then
    echo "No problematic EMR clusters found." >> "$OUTPUT_FILE"
  fi
}

main() {
  write_header
  check_clusters

  cat "$OUTPUT_FILE"
  if grep -q "EMR cluster" "$OUTPUT_FILE" || grep -q "idle" "$OUTPUT_FILE" || grep -q "exceeding" "$OUTPUT_FILE"; then
    send_slack_alert "EMR Monitor" "Findings detected. See report at $OUTPUT_FILE." || true
  fi
}

main "$@"
