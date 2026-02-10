#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ecs-taskdef-auditor.log"
REPORT_FILE="/tmp/ecs-taskdef-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
OLD_REV_THRESHOLD="${ECS_TASKDEF_OLD_REVISIONS:-5}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS ECS Task Definition Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Old revision threshold: $OLD_REV_THRESHOLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_task_family() {
  local family="$1"
  echo "TaskFamily: $family" >> "$REPORT_FILE"

  # list revisions
  revs=$(aws ecs list-task-definitions --family-prefix "$family" --sort DESC --output json 2>/dev/null | jq -r '.taskDefinitionArns[]?')
  rev_count=0
  for r in $revs; do
    rev_count=$((rev_count+1))
  done
  echo "  Revisions: $rev_count" >> "$REPORT_FILE"
  if [ "$rev_count" -gt "$OLD_REV_THRESHOLD" ]; then
    echo "  MANY_REVISIONS: $rev_count > $OLD_REV_THRESHOLD" >> "$REPORT_FILE"
    send_slack_alert "ECS Alert: Task family $family has $rev_count revisions (> $OLD_REV_THRESHOLD)"
  fi

  # check latest revision details
  latest=$(echo "$revs" | head -n1)
  if [ -n "$latest" ]; then
    td=$(aws ecs describe-task-definition --task-definition "$latest" --output json 2>/dev/null || echo '{}')
    echo "  Latest: $latest" >> "$REPORT_FILE"

    # check container images for :latest usage
    echo "$td" | jq -c '.taskDefinition.containerDefinitions[]? // empty' | while read -r c; do
      name=$(echo "$c" | jq -r '.name')
      image=$(echo "$c" | jq -r '.image')
      echo "    Container: $name image=$image" >> "$REPORT_FILE"
      if echo "$image" | grep -E ':latest$' >/dev/null 2>&1; then
        echo "      USES_LATEST_TAG" >> "$REPORT_FILE"
        send_slack_alert "ECS Alert: Task family $family container $name uses :latest tag (image=$image)"
      fi

      # check environment variables for potential plaintext secrets (heuristic)
      echo "$c" | jq -c '.environment[]? // empty' | while read -r env; do
        key=$(echo "$env" | jq -r '.name')
        val=$(echo "$env" | jq -r '.value // empty')
        if echo "$key" | grep -Ei 'password|secret|token|key' >/dev/null 2>&1; then
          echo "      ENV_POTENTIAL_SECRET: $key" >> "$REPORT_FILE"
          send_slack_alert "ECS Alert: Task family $family container $name has env var $key (potential secret)"
        fi
      done
    done
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  aws ecs list-task-definition-families --output json 2>/dev/null | jq -r '.families[]? // empty' | while read -r fam; do
    check_task_family "$fam"
  done

  log_message "ECS task-definition audit written to $REPORT_FILE"
}

main "$@"
