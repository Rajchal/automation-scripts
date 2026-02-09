#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-autoscaling-health-auditor.log"
REPORT_FILE="/tmp/autoscaling-health-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS AutoScaling Health Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_asg() {
  local name="$1"
  echo "AutoScalingGroup: $name" >> "$REPORT_FILE"

  asg_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$name" --output json 2>/dev/null || echo '{"AutoScalingGroups":[]}')
  asg=$(echo "$asg_json" | jq -c '.AutoScalingGroups[0] // empty')
  desired=$(echo "$asg" | jq -r '.DesiredCapacity // 0')
  minsize=$(echo "$asg" | jq -r '.MinSize // 0')
  maxsize=$(echo "$asg" | jq -r '.MaxSize // 0')
  suspended=$(echo "$asg" | jq -c '.SuspendedProcesses // []')

  echo "  Desired=$desired Min=$minsize Max=$maxsize" >> "$REPORT_FILE"

  if [ "$(echo "$suspended" | jq 'length')" -gt 0 ]; then
    echo "  SUSPENDED_PROCESSES:" >> "$REPORT_FILE"
    echo "$suspended" | jq -r '.[] | "    \(.ProcessName)"' >> "$REPORT_FILE"
    send_slack_alert "AutoScaling Alert: ASG $name has suspended processes"
  fi

  # check instances in ASG
  echo "$asg" | jq -c '.Instances[]? // empty' | while read -r inst; do
    iid=$(echo "$inst" | jq -r '.InstanceId')
    lifecycle=$(echo "$inst" | jq -r '.LifecycleState // ""')
    health=$(echo "$inst" | jq -r '.HealthStatus // ""')
    protected=$(echo "$inst" | jq -r '.ProtectedFromScaleIn // false')

    echo "    Instance: $iid lifecycle=$lifecycle health=$health protected=$protected" >> "$REPORT_FILE"

    if [ "$lifecycle" != "InService" ] || [ "$health" != "Healthy" ]; then
      echo "      ISSUE: lifecycle=$lifecycle health=$health" >> "$REPORT_FILE"
      send_slack_alert "AutoScaling Alert: Instance $iid in ASG $name has lifecycle=$lifecycle health=$health"
    fi

    # check EC2 instance status (best-effort)
    inst_status=$(aws ec2 describe-instance-status --instance-ids "$iid" --include-all-instances --output json 2>/dev/null || echo '{}')
    sys_status=$(echo "$inst_status" | jq -r '.InstanceStatuses[0].SystemStatus.Status // empty')
    inststat=$(echo "$inst_status" | jq -r '.InstanceStatuses[0].InstanceStatus.Status // empty')
    if [ -n "$inststat" ] && [ "$inststat" != "ok" ]; then
      echo "      EC2_STATUS: instance-status=$inststat system-status=$sys_status" >> "$REPORT_FILE"
      send_slack_alert "AutoScaling Alert: EC2 instance $iid status=$inststat system=$sys_status"
    fi
  done

  # check desired vs in-service count
  inservice_count=$(echo "$asg" | jq -r '[.Instances[]? | select(.LifecycleState=="InService")] | length')
  echo "  InServiceCount=$inservice_count" >> "$REPORT_FILE"
  if [ "$inservice_count" -lt "$desired" ]; then
    echo "  CAPACITY_MISMATCH: inService($inservice_count) < desired($desired)" >> "$REPORT_FILE"
    send_slack_alert "AutoScaling Alert: ASG $name in-service count $inservice_count is less than desired $desired"
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  aws autoscaling describe-auto-scaling-groups --output json 2>/dev/null | jq -c '.AutoScalingGroups[]? // empty' | while read -r g; do
    name=$(echo "$g" | jq -r '.AutoScalingGroupName')
    check_asg "$name"
  done

  log_message "AutoScaling health audit written to $REPORT_FILE"
}

main "$@"
