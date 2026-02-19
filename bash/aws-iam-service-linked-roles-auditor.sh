#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-iam-service-linked-roles-auditor.sh"
LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"
REPORT_FILE="/tmp/${SCRIPT_NAME%.sh}-$(date +%s).txt"

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

Findings:
EOF
}

main() {
  write_header
  log_message "Starting service-linked-roles auditor"

  # Use the dedicated API when available
  local slr_json
  slr_json=$(aws iam list-service-linked-roles --output json 2>/dev/null || echo '{"ServiceLinkedRoles":[]}')

  local slrs
  slrs=$(echo "$slr_json" | jq -c '.ServiceLinkedRoles[]?') || slrs=""
  if [ -z "$slrs" ]; then
    log_message "No service-linked roles found or AWS CLI failed"
    rm -f "$REPORT_FILE"
    exit 0
  fi

  local any=0
  echo "$slrs" | while read -r s; do
    local role_name
    role_name=$(echo "$s" | jq -r '.RoleName // "<unknown>"')
    local service_name
    service_name=$(echo "$s" | jq -r '.ServiceName // "<unknown>"')
    local created
    created=$(echo "$s" | jq -r '.CreateDate // "<unknown>"')
    local description
    description=$(echo "$s" | jq -r '.Description // ""')

    # Basic sanity checks
    local findings=()
    if [ -z "$service_name" ] || [ "$service_name" = "<unknown>" ]; then
      findings+=("Missing or unknown ServiceName")
    fi
    # If description indicates role was created for a deleted service, flag it
    if echo "$description" | grep -qiE "(deleted|deprecated|removed)" >/dev/null 2>&1; then
      findings+=("Description indicates service may be removed/deprecated: $description")
    fi

    if [ ${#findings[@]} -gt 0 ]; then
      echo "ServiceLinkedRole: $role_name" >> "$REPORT_FILE"
      echo "  ServiceName: $service_name" >> "$REPORT_FILE"
      echo "  Created: $created" >> "$REPORT_FILE"
      for f in "${findings[@]}"; do
        echo "  - $f" >> "$REPORT_FILE"
      done
      echo >> "$REPORT_FILE"
      any=1
      log_message "Findings for $role_name"
    fi
  done

  # Best-effort: find roles under /aws-service-role/ path that are NOT in list-service-linked-roles
  local all_roles
  all_roles=$(aws iam list-roles --query 'Roles[?starts_with(Path, `/aws-service-role/`)].RoleName' --output text 2>/dev/null || true)
  if [ -n "$all_roles" ]; then
    for r in $all_roles; do
      if ! echo "$slr_json" | jq -e --arg rn "$r" '.ServiceLinkedRoles[]? | select(.RoleName == $rn)' >/dev/null 2>&1; then
        echo "Role: $r appears under /aws-service-role/ but not returned by list-service-linked-roles" >> "$REPORT_FILE"
        echo "  - This role may be orphaned or created manually; inspect before deleting." >> "$REPORT_FILE"
        echo >> "$REPORT_FILE"
        any=1
        log_message "Orphaned-like service role found: $r"
      fi
    done
  fi

  if [ -s "$REPORT_FILE" ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "Service-linked-roles auditor found items; report at $REPORT_FILE"
  else
    log_message "No issues found for service-linked roles"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"
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
