#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-iam-service-linked-roles-auditor.sh"
LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"
REPORT_FILE="/tmp/${SCRIPT_NAME%.sh}-$(date +%s).txt"

AGE_DAYS=${SLR_AGE_DAYS:-90}

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
AWS IAM Service-Linked Roles Auditor
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
Age threshold (days): ${AGE_DAYS}

Findings:
EOF
}

main() {
  write_header
  log_message "Starting service-linked roles auditor"

  local list_json
  list_json=$(aws iam list-service-linked-roles --output json 2>/dev/null || echo '{"ServiceLinkedRoles":[]}')

  local items
  items=$(echo "$list_json" | jq -c '.ServiceLinkedRoles[]?') || items=""
  if [ -z "$items" ]; then
    log_message "No service-linked roles found or AWS CLI failed"
    rm -f "$REPORT_FILE"
    exit 0
  fi

  local any=0
  echo "$items" | while read -r item; do
    local arn service created
    arn=$(echo "$item" | jq -r '.Arn // "<unknown>"')
    service=$(echo "$item" | jq -r '.ServiceName // "<unknown>"')
    created=$(echo "$item" | jq -r '.CreateDate // .CreatedDate // empty') || created=""

    local age=0
    if [ -n "$created" ] && [ "$created" != "null" ]; then
      age=$(( ( $(date +%s) - $(date -d "$created" +%s) ) / 86400 )) || age=0
    fi

    if [ "$age" -ge "$AGE_DAYS" ]; then
      echo "ServiceLinkedRole: $arn" >> "$REPORT_FILE"
      echo "  Service: $service" >> "$REPORT_FILE"
      echo "  Created: ${created:-unknown}" >> "$REPORT_FILE"
      echo "  AgeDays: $age (>= ${AGE_DAYS}) - review for necessity" >> "$REPORT_FILE"
      echo >> "$REPORT_FILE"
      any=1
      log_message "Stale service-linked role: $arn (age ${age} days)"
    else
      # include brief listing for visibility (optional)
      echo "ServiceLinkedRole: $arn - age ${age} days" >> "$REPORT_FILE" 2>/dev/null || true
    fi
  done

  # If report only contains listing and no stale entries, remove it
  if grep -q "review for necessity" "$REPORT_FILE" 2>/dev/null; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "Service-linked roles auditor found aged roles. See $REPORT_FILE on host."
  else
    log_message "No aged service-linked roles detected"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"
