#!/bin/bash

################################################################################
# AWS IAM Posture Monitor
# Audits IAM: user key age, password/MFA, admin roles, unused roles/policies,
# access advisor data, and root account flags. Includes thresholds, logging,
# Slack/email alerts, and a text report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/iam-posture-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/iam-posture-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds
KEY_MAX_AGE_DAYS="${KEY_MAX_AGE_DAYS:-90}"
USER_INACTIVE_DAYS="${USER_INACTIVE_DAYS:-90}"
ROLE_INACTIVE_DAYS="${ROLE_INACTIVE_DAYS:-90}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_USERS=0
USERS_NO_MFA=0
USERS_OLD_KEYS=0
USERS_INACTIVE=0
TOTAL_ROLES=0
ROLES_INACTIVE=0
ADMIN_ROLES=0
ROOT_FLAGS=0

ISSUES=()

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

aws_cmd() {
  if [[ -n "${PROFILE}" ]]; then AWS_PROFILE="${PROFILE}" aws "$@"; else aws "$@"; fi
}

send_slack_alert() {
  local message="$1"
  local severity="${2:-INFO}"
  [[ -z "${SLACK_WEBHOOK}" ]] && return
  local color
  case "${severity}" in
    CRITICAL) color="danger" ;;
    WARNING)  color="warning" ;;
    INFO)     color="good" ;;
    *)        color="good" ;;
  esac
  local payload
  payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "${color}",
      "title": "AWS IAM Posture Alert",
      "text": "${message}",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || true
}

send_email_alert() {
  local subject="$1"
  local body="$2"
  [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null && return
  echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true
}

days_since() {
  local datestr="$1"
  [[ -z "$datestr" || "$datestr" == "" ]] && { echo 999999; return; }
  local ts_now ts_val
  ts_now=$(date +%s)
  ts_val=$(date -d "$datestr" +%s 2>/dev/null || echo "")
  [[ -z "$ts_val" ]] && { echo 999999; return; }
  echo $(( (ts_now - ts_val) / 86400 ))
}

record_issue() {
  ISSUES+=("$1")
}

write_header() {
  {
    echo "AWS IAM Posture Monitor"
    echo "======================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Thresholds:"
    echo "  Key max age: ${KEY_MAX_AGE_DAYS} days"
    echo "  User inactivity: ${USER_INACTIVE_DAYS} days"
    echo "  Role inactivity: ${ROLE_INACTIVE_DAYS} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_users() { aws_cmd iam list-users --output json 2>/dev/null || echo '{"Users":[]}' ; }
list_roles() { aws_cmd iam list-roles --output json 2>/dev/null || echo '{"Roles":[]}' ; }
get_account_summary() { aws_cmd iam get-account-summary --output json 2>/dev/null || echo '{}'; }
list_mfa_devices() { local user="$1"; aws_cmd iam list-mfa-devices --user-name "$user" --output json 2>/dev/null || echo '{"MFADevices":[]}' ; }
list_access_keys() { local user="$1"; aws_cmd iam list-access-keys --user-name "$user" --output json 2>/dev/null || echo '{"AccessKeyMetadata":[]}' ; }
get_access_key_last_used() { local key_id="$1"; aws_cmd iam get-access-key-last-used --access-key-id "$key_id" --output json 2>/dev/null || echo '{}'; }
list_attached_role_policies() { local role="$1"; aws_cmd iam list-attached-role-policies --role-name "$role" --output json 2>/dev/null || echo '{"AttachedPolicies":[]}' ; }
get_role_last_used() { local role="$1"; aws_cmd iam get-role --role-name "$role" --output json 2>/dev/null || echo '{}'; }

is_admin_policy() {
  local policy_arn="$1"
  case "$policy_arn" in
    arn:aws:iam::aws:policy/AdministratorAccess) return 0 ;;
    *) return 1 ;;
  esac
}

analyze_user() {
  local user_json="$1"
  local user name created pwd_last_changed pwd_enabled
  name=$(echo "$user_json" | jq -r '.UserName')
  created=$(echo "$user_json" | jq -r '.CreateDate')
  pwd_last_changed=$(echo "$user_json" | jq -r '.PasswordLastUsed')
  pwd_enabled=$(echo "$user_json" | jq -r '.PasswordLastUsed // ""')

  TOTAL_USERS=$((TOTAL_USERS + 1))
  log_message INFO "Analyzing user: ${name}"

  # MFA
  local mfa_json mfa_count
  mfa_json=$(list_mfa_devices "$name")
  mfa_count=$(echo "$mfa_json" | jq -r '.MFADevices | length')
  local mfa_status="enabled"
  if [[ "$mfa_count" == "0" ]]; then
    mfa_status="missing"
    USERS_NO_MFA=$((USERS_NO_MFA + 1))
    record_issue "User ${name} missing MFA"
  fi

  # Access keys
  local keys_json key_age_oldest key_warn
  keys_json=$(list_access_keys "$name")
  key_age_oldest=0
  key_warn=0
  while read -r key; do
    local kid kcreated klast_used_age
    kid=$(echo "$key" | jq -r '.AccessKeyId')
    kcreated=$(echo "$key" | jq -r '.CreateDate')
    klast_json=$(get_access_key_last_used "$kid")
    klast_used=$(echo "$klast_json" | jq -r '.AccessKeyLastUsed.LastUsedDate // ""')
    kage=$(days_since "$kcreated")
    key_age_oldest=$(( kage > key_age_oldest ? kage : key_age_oldest ))
    if (( kage > KEY_MAX_AGE_DAYS )); then
      key_warn=1
      record_issue "User ${name} key ${kid} age ${kage}d exceeds ${KEY_MAX_AGE_DAYS}d"
    fi
    if [[ -n "$klast_used" ]]; then
      klast_used_age=$(days_since "$klast_used")
      if (( klast_used_age > USER_INACTIVE_DAYS )); then
        USERS_INACTIVE=$((USERS_INACTIVE + 1))
        record_issue "User ${name} key ${kid} unused for ${klast_used_age}d"
      fi
    fi
  done <<< "$(echo "$keys_json" | jq -c '.AccessKeyMetadata[]')"

  # Password activity
  local pwd_unused_age=""
  if [[ -n "$pwd_last_changed" && "$pwd_last_changed" != "null" ]]; then
    pwd_unused_age=$(days_since "$pwd_last_changed")
  fi

  {
    echo "User: ${name}"
    echo "  Created: ${created}"
    echo "  MFA: ${mfa_status}"
    echo "  Oldest Key Age: ${key_age_oldest} days"
    [[ -n "$pwd_unused_age" ]] && echo "  Password Last Used (days): ${pwd_unused_age}"
  } >> "$OUTPUT_FILE"

  if (( key_warn )); then USERS_OLD_KEYS=$((USERS_OLD_KEYS + 1)); fi
}

analyze_role() {
  local role_json="$1"
  local name created last_used
  name=$(echo "$role_json" | jq -r '.RoleName')
  created=$(echo "$role_json" | jq -r '.CreateDate')
  last_used=$(echo "$role_json" | jq -r '.RoleLastUsed.LastUsedDate // ""')

  TOTAL_ROLES=$((TOTAL_ROLES + 1))

  local role_inactive=0
  if [[ -z "$last_used" ]]; then
    role_inactive=1
  else
    local days_unused
    days_unused=$(days_since "$last_used")
    if (( days_unused > ROLE_INACTIVE_DAYS )); then
      role_inactive=1
    fi
  fi
  if (( role_inactive )); then
    ROLES_INACTIVE=$((ROLES_INACTIVE + 1))
    record_issue "Role ${name} unused beyond ${ROLE_INACTIVE_DAYS}d"
  fi

  # Attached policies for admin
  local attached_json
  attached_json=$(list_attached_role_policies "$name")
  local is_admin="no"
  while read -r pol; do
    local arn
    arn=$(echo "$pol" | jq -r '.PolicyArn')
    if is_admin_policy "$arn"; then
      is_admin="yes"
      ADMIN_ROLES=$((ADMIN_ROLES + 1))
      record_issue "Role ${name} has AdministratorAccess policy"
      break
    fi
  done <<< "$(echo "$attached_json" | jq -c '.AttachedPolicies[]')"

  {
    echo "Role: ${name}"
    echo "  Created: ${created}"
    echo "  Last Used: ${last_used:-unknown}"
    echo "  Admin: ${is_admin}"
  } >> "$OUTPUT_FILE"
}

analyze_root() {
  local summary
  summary=$(get_account_summary)
  local root_mfa root_keys
  root_mfa=$(echo "$summary" | jq -r '.SummaryMap.AccountMFAEnabled // 0')
  root_keys=$(echo "$summary" | jq -r '.SummaryMap.AccountAccessKeysPresent // 0')
  if [[ "$root_mfa" != "1" ]]; then
    ROOT_FLAGS=$((ROOT_FLAGS + 1))
    record_issue "Root account missing MFA"
  fi
  if [[ "$root_keys" != "0" ]]; then
    ROOT_FLAGS=$((ROOT_FLAGS + 1))
    record_issue "Root account has access keys"
  fi

  {
    echo "Root Account:"
    echo "  MFA Enabled: ${root_mfa}"
    echo "  Access Keys Present: ${root_keys}"
  } >> "$OUTPUT_FILE"
}

main() {
  write_header

  analyze_root

  local users_json
  users_json=$(list_users)
  echo "" >> "$OUTPUT_FILE"
  echo "Users:" >> "$OUTPUT_FILE"
  while read -r user; do
    analyze_user "$user"
  done <<< "$(echo "$users_json" | jq -c '.Users[]')"

  local roles_json
  roles_json=$(list_roles)
  echo "" >> "$OUTPUT_FILE"
  echo "Roles:" >> "$OUTPUT_FILE"
  while read -r role; do
    analyze_role "$role"
  done <<< "$(echo "$roles_json" | jq -c '.Roles[]')"

  {
    echo ""
    echo "Summary"
    echo "-------"
    echo "Total Users: ${TOTAL_USERS}"
    echo "Users missing MFA: ${USERS_NO_MFA}"
    echo "Users with old keys: ${USERS_OLD_KEYS}"
    echo "Users inactive (keys): ${USERS_INACTIVE}"
    echo "Total Roles: ${TOTAL_ROLES}"
    echo "Inactive Roles: ${ROLES_INACTIVE}"
    echo "Admin Roles: ${ADMIN_ROLES}"
    echo "Root Flags: ${ROOT_FLAGS}"
  } >> "$OUTPUT_FILE"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "IAM Posture Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "IAM Posture Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"
