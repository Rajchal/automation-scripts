#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-ec2-instance-profile-auditor.sh"
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
AWS EC2 Instance Profile Auditor
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

Findings:
EOF
}

policy_has_wildcard_allow() {
  local policy_json="$1"
  echo "$policy_json" | jq -e '
    .Statement // [] |
    (if type=="object" then [.] else . end) |
    map(select(.Effect=="Allow")) |
    map(select(
      (.Action=="*") or
      (.Action | (if type=="array" then any(.=="*") else false end)) or
      (.Resource=="*") or
      (.Resource | (if type=="array" then any(.=="*") else false end))
    )) | length > 0
  '
}

check_role_policies() {
  local role_name="$1"
  local findings=()

  # inline
  local inline
  inline=$(aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames[]' --output text 2>/dev/null || true)
  if [ -n "$inline" ]; then
    for pn in $inline; do
      local doc
      doc=$(aws iam get-role-policy --role-name "$role_name" --policy-name "$pn" --query 'PolicyDocument' --output json 2>/dev/null || echo '{}')
      if policy_has_wildcard_allow "$doc" >/dev/null 2>&1; then
        findings+=("INLINE_POLICY:$pn has wildcard Allow")
      fi
    done
  fi

  # attached
  local attached
  attached=$(aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)
  if [ -n "$attached" ]; then
    for arn in $attached; do
      local ver
      ver=$(aws iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text 2>/dev/null || true)
      if [ -n "$ver" ]; then
        local doc
        doc=$(aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" --query 'PolicyVersion.Document' --output json 2>/dev/null || echo '{}')
        if policy_has_wildcard_allow "$doc" >/dev/null 2>&1; then
          findings+=("MANAGED_POLICY:${arn} has wildcard Allow")
        fi
      fi
    done
  fi

  if [ ${#findings[@]} -gt 0 ]; then
    echo "Role: $role_name" >> "$REPORT_FILE"
    for f in "${findings[@]}"; do
      echo "  - $f" >> "$REPORT_FILE"
    done
    echo >> "$REPORT_FILE"
    return 0
  fi
  return 1
}

main() {
  write_header
  log_message "Starting EC2 instance-profile auditor"

  local profiles
  profiles=$(aws iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null || true)
  if [ -z "$profiles" ]; then
    log_message "No instance profiles found or AWS CLI failed"
    rm -f "$REPORT_FILE"
    exit 0
  fi

  local any=0
  for p in $profiles; do
    local ip_json
    ip_json=$(aws iam get-instance-profile --instance-profile-name "$p" --output json 2>/dev/null || echo '{}')
    local roles
    roles=$(echo "$ip_json" | jq -r '.InstanceProfile.Roles[].RoleName // empty' 2>/dev/null || true)
    if [ -z "$roles" ]; then
      echo "InstanceProfile: $p has no roles attached" >> "$REPORT_FILE"
      any=1
      continue
    fi
    for r in $roles; do
      if check_role_policies "$r"; then
        any=1
        log_message "Findings for role $r attached to instance profile $p"
      fi
    done
  done

  if [ "$any" -eq 1 ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "EC2 instance-profile auditor found issues. See $REPORT_FILE on host."
  else
    log_message "No issues found for EC2 instance profiles"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"
