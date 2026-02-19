#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-iam-role-session-duration-auditor.sh"
LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"
REPORT_FILE="/tmp/${SCRIPT_NAME%.sh}-$(date +%s).txt"

# Default maximum acceptable session duration (seconds). Override with env var.
MAX_ALLOWED_SESSION_SECONDS=${MAX_SESSION_SECONDS:-3600}

log_message() {
  local msg="$1"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - ${msg}" | tee -a "$LOG_FILE"
}

send_slack_alert() {
  local text="$1"
  if [ -n "${SLACK_WEBHOOK:-}" ]; then
    jq -n --arg t "$text" '{text:$t}' | curl -s -X POST -H 'Content-type: application/json' --data @- "$SLACK_WEBHOOK" >/dev/null || true
  fi
}

write_header() {
  cat > "$REPORT_FILE" <<EOF
AWS IAM Role Session Duration Auditor
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
MAX_ALLOWED_SESSION_SECONDS=$MAX_ALLOWED_SESSION_SECONDS

Findings:
EOF
}

check_role() {
  local role_name="$1"
  local role_json
  role_json=$(aws iam get-role --role-name "$role_name" --query 'Role' --output json 2>/dev/null || echo '{}')
  if [ "$role_json" = "{}" ]; then
    return 1
  fi
  local msd
  msd=$(echo "$role_json" | jq -r '.MaxSessionDuration // 3600')
  if [ -z "$msd" ] || [ "$msd" = "null" ]; then
    msd=3600
  fi
  if [ "$msd" -gt "$MAX_ALLOWED_SESSION_SECONDS" ]; then
    echo "Role: $role_name" >> "$REPORT_FILE"
    echo "  - MaxSessionDuration: ${msd}s exceeds allowed ${MAX_ALLOWED_SESSION_SECONDS}s" >> "$REPORT_FILE"
    echo >> "$REPORT_FILE"
    return 0
  fi
  return 1
}

main() {
  write_header
  log_message "Starting IAM role session-duration auditor (allowed=${MAX_ALLOWED_SESSION_SECONDS}s)"

  local roles
  roles=$(aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null || true)
  if [ -z "$roles" ]; then
    log_message "No roles found or AWS CLI failed"
    rm -f "$REPORT_FILE"
    exit 0
  fi

  local any=0
  for r in $roles; do
    if check_role "$r"; then
      any=1
      log_message "Role $r has excessive MaxSessionDuration"
    fi
  done

  if [ "$any" -eq 1 ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "IAM role session-duration auditor found roles exceeding ${MAX_ALLOWED_SESSION_SECONDS}s. See $REPORT_FILE on host."
  else
    log_message "No roles with excessive session duration found"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"
