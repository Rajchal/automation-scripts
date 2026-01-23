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
