#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-iam-role-trust-policy-auditor.sh"
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
AWS IAM Role Trust-Policy Auditor
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

Findings:
EOF
}

check_assume_role_policy() {
  local role_name="$1"
  local doc
  doc=$(aws iam get-role --role-name "$role_name" --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null || echo '{}')
  if [ "$doc" = "{}" ]; then
    return 1
  fi

  # Look for wildcard principals or ExternalAccount principals
  local wildcard_principal
  wildcard_principal=$(echo "$doc" | jq -e '.Statement[]? | select(.Effect=="Allow") | .Principal // {} | (if (.AWS=="*" or .=="*") then true elif (.AWS // "" | type=="string" and .=="*") then true else false end) ' 2>/dev/null || true)

  local any_wild=false
  if echo "$doc" | jq -e '.Statement[]? | select(.Effect=="Allow") | .Principal // {} | (.AWS=="*" or .=="*" or (.AWS? | type=="array" and any(.=="*")) )' >/dev/null 2>&1; then
    any_wild=true
  fi

  # Check for Service principals that are overly broad (e.g., "*" or all services)
  local any_service_wild=false
  if echo "$doc" | jq -e '.Statement[]? | select(.Effect=="Allow") | .Principal.Service? // empty | (.=="*" or type=="array" and any(.=="*"))' >/dev/null 2>&1; then
    any_service_wild=true
  fi

  # Check for federated principals allowing any (e.g., Cognito / SAML with broad conditions)
  local broad_federated=false
  if echo "$doc" | jq -e '.Statement[]? | select(.Effect=="Allow") | .Principal.Federated? // empty | (.=="*" )' >/dev/null 2>&1; then
    broad_federated=true
  fi

  if [ "$any_wild" = true ] || [ "$any_service_wild" = true ] || [ "$broad_federated" = true ]; then
    echo "Role: $role_name" >> "$REPORT_FILE"
    if [ "$any_wild" = true ]; then
      echo "  - Trust policy allows wildcard Principal (AWS or *)" >> "$REPORT_FILE"
    fi
    if [ "$any_service_wild" = true ]; then
      echo "  - Trust policy has wildcard Service principal" >> "$REPORT_FILE"
    fi
    if [ "$broad_federated" = true ]; then
      echo "  - Trust policy has broad Federated principal" >> "$REPORT_FILE"
    fi
    echo >> "$REPORT_FILE"
    return 0
  fi
  return 1
}

main() {
  write_header
  log_message "Starting IAM role trust-policy auditor"

  local roles
  roles=$(aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null || true)
  if [ -z "$roles" ]; then
    log_message "No roles found or AWS CLI failed"
    rm -f "$REPORT_FILE"
    exit 0
  fi

  local found=0
  for r in $roles; do
    if check_assume_role_policy "$r"; then
      found=1
      log_message "Trust-policy issue found for role $r"
    fi
  done

  if [ "$found" -eq 1 ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "IAM role trust-policy auditor found issues. See $REPORT_FILE on host."
  else
    log_message "No trust-policy problems detected"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"
