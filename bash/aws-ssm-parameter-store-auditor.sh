#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ssm-parameter-store-auditor.log"
REPORT_FILE="/tmp/ssm-parameter-store-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
SENSITIVE_NAME_PATTERN="PASSWORD|SECRET|TOKEN|KEY|AWS_SECRET|ACCESS_KEY"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS SSM Parameter Store Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "Sensitive name pattern: ${SENSITIVE_NAME_PATTERN}" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# Do NOT retrieve parameter values to avoid exposing secrets; inspect metadata only.
check_parameter_meta() {
  local name="$1"
  local typ="$2"
  local keyid="$3"
  local lastModified="$4"

  echo "Parameter: $name type=$typ keyId=${keyid:-none} lastModified=${lastModified:-unknown}" >> "$REPORT_FILE"

  if [ "$typ" = "String" ]; then
    # heuristics: parameter names that look sensitive
    if echo "$name" | grep -Ei "$SENSITIVE_NAME_PATTERN" >/dev/null 2>&1; then
      echo "  POSSIBLE_PLAINTEXT_SECRET_NAME" >> "$REPORT_FILE"
      send_slack_alert "SSM Alert: Parameter $name is type=String and matches sensitive name pattern"
    fi
  fi

  if [ "$typ" = "SecureString" ]; then
    if [ -z "$keyid" ] || [ "$keyid" = "null" ]; then
      echo "  SECURESTRING_MISSING_KMS_KEY" >> "$REPORT_FILE"
      send_slack_alert "SSM Alert: SecureString parameter $name has no KMS key specified"
    else
      echo "  Secure with KMS key: $keyid" >> "$REPORT_FILE"
    fi
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  next_token=""
  while :; do
    if [ -z "$next_token" ]; then
      out=$(aws ssm describe-parameters --output json 2>/dev/null || echo '{"Parameters":[]}')
    else
      out=$(aws ssm describe-parameters --output json --next-token "$next_token" 2>/dev/null || echo '{"Parameters":[]}')
    fi

    echo "$out" | jq -c '.Parameters[]? // empty' | while read -r p; do
      pname=$(echo "$p" | jq -r '.Name')
      ptype=$(echo "$p" | jq -r '.Type')
      pkid=$(echo "$p" | jq -r '.KeyId // empty')
      lastMod=$(echo "$p" | jq -r '.LastModifiedDate // empty')
      check_parameter_meta "$pname" "$ptype" "$pkid" "$lastMod"
    done

    next_token=$(echo "$out" | jq -r '.NextToken // empty')
    if [ -z "$next_token" ]; then
      break
    fi
  done

  log_message "SSM Parameter Store audit written to $REPORT_FILE"
}

main "$@"
