#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-iam-password-policy-auditor.sh"
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
AWS IAM Account Password Policy Auditor
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

Findings:
EOF
}

main() {
  write_header
  log_message "Starting IAM password policy auditor"

  local policy_json
  policy_json=$(aws iam get-account-password-policy --output json 2>/dev/null || echo '{}')
  if [ "$policy_json" = "{}" ]; then
    echo "No account password policy found or AWS CLI failed to retrieve it." >> "$REPORT_FILE"
    log_message "No password policy found"
    send_slack_alert "IAM password policy missing or cannot be retrieved on host."
    exit 0
  fi

  local min_len require_sym require_num require_upper require_lower allow_users_change max_age expire_password
  min_len=$(echo "$policy_json" | jq -r '.PasswordPolicy.MinimumPasswordLength // 0')
  require_sym=$(echo "$policy_json" | jq -r '.PasswordPolicy.RequireSymbols // false')
  require_num=$(echo "$policy_json" | jq -r '.PasswordPolicy.RequireNumbers // false')
  require_upper=$(echo "$policy_json" | jq -r '.PasswordPolicy.RequireUppercaseCharacters // false')
  require_lower=$(echo "$policy_json" | jq -r '.PasswordPolicy.RequireLowercaseCharacters // false')
  allow_users_change=$(echo "$policy_json" | jq -r '.PasswordPolicy.AllowUsersToChangePassword // false')
  max_age=$(echo "$policy_json" | jq -r '.PasswordPolicy.MaxPasswordAge // 0')
  expire_password=$(echo "$policy_json" | jq -r '.PasswordPolicy.ExpirePasswords // false')

  echo "Password policy summary:" >> "$REPORT_FILE"
  echo "  Minimum length: $min_len" >> "$REPORT_FILE"
  echo "  Require symbols: $require_sym" >> "$REPORT_FILE"
  echo "  Require numbers: $require_num" >> "$REPORT_FILE"
  echo "  Require uppercase: $require_upper" >> "$REPORT_FILE"
  echo "  Require lowercase: $require_lower" >> "$REPORT_FILE"
  echo "  Allow users to change password: $allow_users_change" >> "$REPORT_FILE"
  echo "  Max password age (days): $max_age" >> "$REPORT_FILE"
  echo "  Expire passwords: $expire_password" >> "$REPORT_FILE"
  echo >> "$REPORT_FILE"

  local issues=()
  if [ "$min_len" -lt 12 ]; then
    issues+=("MinimumPasswordLength is less than 12 (current=$min_len)")
  fi
  if [ "$require_sym" != "true" ]; then
    issues+=("RequireSymbols is not enabled")
  fi
  if [ "$require_num" != "true" ]; then
    issues+=("RequireNumbers is not enabled")
  fi
  if [ "$require_upper" != "true" ]; then
    issues+=("RequireUppercaseCharacters is not enabled")
  fi
  if [ "$require_lower" != "true" ]; then
    issues+=("RequireLowercaseCharacters is not enabled")
  fi
  if [ "$max_age" -eq 0 ]; then
    issues+=("MaxPasswordAge is not set (passwords do not expire)")
  elif [ "$max_age" -gt 365 ]; then
    issues+=("MaxPasswordAge is long (>365 days): $max_age")
  fi

  if [ ${#issues[@]} -gt 0 ]; then
    echo "Issues found:" >> "$REPORT_FILE"
    for it in "${issues[@]}"; do
      echo "  - $it" >> "$REPORT_FILE"
    done
    log_message "Password policy issues detected"
    send_slack_alert "IAM password policy issues detected. See $REPORT_FILE on host."
  else
    echo "No issues detected with account password policy." >> "$REPORT_FILE"
    log_message "Password policy OK"
  fi
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-iam-password-policy-auditor.log"
REPORT_FILE="/tmp/iam-password-policy-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MIN_LENGTH_WARN="${IAM_MIN_PASSWORD_LENGTH_WARN:-14}"
MAX_AGE_WARN="${IAM_PASSWORD_MAX_AGE_WARN:-90}"
REQUIRE_SYMBOLS="${IAM_REQUIRE_SYMBOLS:-true}"
REQUIRE_NUMBERS="${IAM_REQUIRE_NUMBERS:-true}"
REQUIRE_UPPER="${IAM_REQUIRE_UPPER:-true}"
REQUIRE_LOWER="${IAM_REQUIRE_LOWER:-true}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "IAM Password Policy Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (api calls): $REGION" >> "$REPORT_FILE"
  echo "Warn thresholds: min_length=$MIN_LENGTH_WARN max_age_days=$MAX_AGE_WARN require_symbols=$REQUIRE_SYMBOLS require_numbers=$REQUIRE_NUMBERS require_upper=$REQUIRE_UPPER require_lower=$REQUIRE_LOWER" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  # Try to get account password policy; if none exists, aws returns non-zero
  policy_json=$(aws iam get-account-password-policy --output json 2>/dev/null || echo '{}')

  if [ "$policy_json" = "{}" ]; then
    echo "No account password policy set." >> "$REPORT_FILE"
    send_slack_alert "IAM Alert: No account password policy is set. Recommend enforcing a strong password policy." 
    log_message "No IAM account password policy found"
    exit 0
  fi

  min_length=$(echo "$policy_json" | jq -r '.PasswordPolicy.MinimumPasswordLength // 0')
  require_symbols=$(echo "$policy_json" | jq -r '.PasswordPolicy.RequireSymbols // false')
  require_numbers=$(echo "$policy_json" | jq -r '.PasswordPolicy.RequireNumbers // false')
  require_upper=$(echo "$policy_json" | jq -r '.PasswordPolicy.RequireUppercaseCharacters // false')
  require_lower=$(echo "$policy_json" | jq -r '.PasswordPolicy.RequireLowercaseCharacters // false')
  allow_change=$(echo "$policy_json" | jq -r '.PasswordPolicy.AllowUsersToChangePassword // false')
  max_age=$(echo "$policy_json" | jq -r '.PasswordPolicy.MaxPasswordAge // 0')
  password_reuse_prevention=$(echo "$policy_json" | jq -r '.PasswordPolicy.PasswordReusePrevention // 0')

  echo "PasswordPolicy:" >> "$REPORT_FILE"
  echo "  MinimumPasswordLength: $min_length" >> "$REPORT_FILE"
  echo "  RequireSymbols: $require_symbols" >> "$REPORT_FILE"
  echo "  RequireNumbers: $require_numbers" >> "$REPORT_FILE"
  echo "  RequireUppercaseCharacters: $require_upper" >> "$REPORT_FILE"
  echo "  RequireLowercaseCharacters: $require_lower" >> "$REPORT_FILE"
  echo "  AllowUsersToChangePassword: $allow_change" >> "$REPORT_FILE"
  echo "  MaxPasswordAge: $max_age" >> "$REPORT_FILE"
  echo "  PasswordReusePrevention: $password_reuse_prevention" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  weak_found=0

  if [ "$min_length" -lt "$MIN_LENGTH_WARN" ]; then
    send_slack_alert "IAM Alert: Minimum password length is $min_length (recommended >= $MIN_LENGTH_WARN)."
    weak_found=1
  fi

  if [ "$REQUIRE_SYMBOLS" = "true" ] && [ "$require_symbols" != "true" ]; then
    send_slack_alert "IAM Alert: Password policy does not require symbols."
    weak_found=1
  fi

  if [ "$REQUIRE_NUMBERS" = "true" ] && [ "$require_numbers" != "true" ]; then
    send_slack_alert "IAM Alert: Password policy does not require numbers."
    weak_found=1
  fi

  if [ "$REQUIRE_UPPER" = "true" ] && [ "$require_upper" != "true" ]; then
    send_slack_alert "IAM Alert: Password policy does not require uppercase characters."
    weak_found=1
  fi

  if [ "$REQUIRE_LOWER" = "true" ] && [ "$require_lower" != "true" ]; then
    send_slack_alert "IAM Alert: Password policy does not require lowercase characters."
    weak_found=1
  fi

  if [ "$max_age" -gt 0 ] && [ "$max_age" -gt "$MAX_AGE_WARN" ]; then
    send_slack_alert "IAM Alert: Max password age is $max_age days (recommended <= $MAX_AGE_WARN days)."
    weak_found=1
  fi

  if [ "$weak_found" -eq 0 ]; then
    echo "Password policy meets configured warning thresholds." >> "$REPORT_FILE"
  else
    echo "Password policy has issues (see Slack alerts)." >> "$REPORT_FILE"
  fi

  log_message "IAM password policy audit written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-iam-password-policy-auditor.log"
REPORT_FILE="/tmp/iam-password-policy-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MIN_LENGTH="${IAM_PASSWORD_MIN_LENGTH:-14}"
REQUIRE_SYMBOLS="${IAM_PASSWORD_REQUIRE_SYMBOLS:-true}"
REQUIRE_NUMBERS="${IAM_PASSWORD_REQUIRE_NUMBERS:-true}"
REQUIRE_UPPERCASE="${IAM_PASSWORD_REQUIRE_UPPERCASE:-true}"
REQUIRE_LOWERCASE="${IAM_PASSWORD_REQUIRE_LOWERCASE:-true}"
MAX_AGE_DAYS="${IAM_PASSWORD_MAX_AGE_DAYS:-90}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "IAM Password Policy Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Expected min length: $MIN_LENGTH" >> "$REPORT_FILE"
  echo "Expected require symbols: $REQUIRE_SYMBOLS" >> "$REPORT_FILE"
  echo "Expected require numbers: $REQUIRE_NUMBERS" >> "$REPORT_FILE"
  echo "Expected require upper: $REQUIRE_UPPERCASE" >> "$REPORT_FILE"
  echo "Expected require lower: $REQUIRE_LOWERCASE" >> "$REPORT_FILE"
  echo "Expected max age (days): $MAX_AGE_DAYS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  policy_json=$(aws iam get-account-password-policy --output json 2>/dev/null || echo '{}')

  if [ "$policy_json" = "{}" ]; then
    echo "No account password policy set." >> "$REPORT_FILE"
    send_slack_alert "IAM Alert: No account password policy is configured."
    log_message "No IAM account password policy"
    exit 0
  fi

  min_length=$(echo "$policy_json" | jq -r '.PasswordPolicy.MinimumPasswordLength // 0')
  require_symbols=$(echo "$policy_json" | jq -r '.PasswordPolicy.RequireSymbols // false')
  require_numbers=$(echo "$policy_json" | jq -r '.PasswordPolicy.RequireNumbers // false')
  require_upper=$(echo "$policy_json" | jq -r '.PasswordPolicy.RequireUppercaseCharacters // false')
  require_lower=$(echo "$policy_json" | jq -r '.PasswordPolicy.RequireLowercaseCharacters // false')
  max_age=$(echo "$policy_json" | jq -r '.PasswordPolicy.MaxPasswordAge // 0')
  allow_users_change_password=$(echo "$policy_json" | jq -r '.PasswordPolicy.AllowUsersToChangePassword // true')

  echo "Detected password policy:" >> "$REPORT_FILE"
  echo "MinimumPasswordLength: $min_length" >> "$REPORT_FILE"
  echo "RequireSymbols: $require_symbols" >> "$REPORT_FILE"
  echo "RequireNumbers: $require_numbers" >> "$REPORT_FILE"
  echo "RequireUppercaseCharacters: $require_upper" >> "$REPORT_FILE"
  echo "RequireLowercaseCharacters: $require_lower" >> "$REPORT_FILE"
  echo "MaxPasswordAge: $max_age" >> "$REPORT_FILE"
  echo "AllowUsersToChangePassword: $allow_users_change_password" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  noncompliant=0

  if [ "$min_length" -lt "$MIN_LENGTH" ]; then
    send_slack_alert "IAM Alert: MinimumPasswordLength is $min_length (< $MIN_LENGTH)"
    noncompliant=$((noncompliant+1))
  fi

  if [ "$REQUIRE_SYMBOLS" = "true" ] && [ "$require_symbols" != "true" ]; then
    send_slack_alert "IAM Alert: Password policy does not require symbols"
    noncompliant=$((noncompliant+1))
  fi

  if [ "$REQUIRE_NUMBERS" = "true" ] && [ "$require_numbers" != "true" ]; then
    send_slack_alert "IAM Alert: Password policy does not require numbers"
    noncompliant=$((noncompliant+1))
  fi

  if [ "$REQUIRE_UPPERCASE" = "true" ] && [ "$require_upper" != "true" ]; then
    send_slack_alert "IAM Alert: Password policy does not require uppercase characters"
    noncompliant=$((noncompliant+1))
  fi

  if [ "$REQUIRE_LOWERCASE" = "true" ] && [ "$require_lower" != "true" ]; then
    send_slack_alert "IAM Alert: Password policy does not require lowercase characters"
    noncompliant=$((noncompliant+1))
  fi

  if [ "$max_age" -eq 0 ] || [ "$max_age" -gt "$MAX_AGE_DAYS" ]; then
    send_slack_alert "IAM Alert: MaxPasswordAge is $max_age (expected <= $MAX_AGE_DAYS)"
    noncompliant=$((noncompliant+1))
  fi

  if [ "$noncompliant" -eq 0 ]; then
    echo "Password policy meets configured thresholds." >> "$REPORT_FILE"
  else
    echo "Password policy has $noncompliant non-compliant settings." >> "$REPORT_FILE"
  fi

  log_message "IAM password policy report written to $REPORT_FILE (noncompliant=$noncompliant)"
}

main "$@"
