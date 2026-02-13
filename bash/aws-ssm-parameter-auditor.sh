#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ssm-parameter-auditor.log"
REPORT_FILE="/tmp/ssm-parameter-auditor-$(date +%Y%m%d%H%M%S).txt"
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
  echo "AWS SSM Parameter Store Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

is_secret_name() {
  echo "$1" | grep -Ei "PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|AWS_SECRET|ACCESS_KEY" >/dev/null 2>&1
}

check_parameter() {
  local name="$1"
  # get metadata
  meta=$(aws ssm describe-parameters --parameter-filters Key=Name,Values="$name" --output json 2>/dev/null || echo '{}')
  # describe-parameters may return minimal info; use get-parameter for details (without decryption)
  param=$(aws ssm get-parameter --name "$name" --with-decryption false --output json 2>/dev/null || echo '{}')
  ptype=$(echo "$param" | jq -r '.Parameter.Type // ""')
  keyid=$(echo "$param" | jq -r '.Parameter.KeyId // empty')
  last_modified=$(echo "$param" | jq -r '.Parameter.LastModifiedDate // empty')

  echo "Parameter: $name type=$ptype keyid=${keyid:-unset} lastModified=${last_modified:-unset}" >> "$REPORT_FILE"

  if [ "$ptype" = "String" ] && is_secret_name "$name"; then
    echo "  POSSIBLE_PLAINTEXT_SECRET: name suggests secret but stored as String" >> "$REPORT_FILE"
    send_slack_alert "SSM Alert: Parameter $name looks like a secret but is stored as String (not SecureString)"
  fi

  if [ "$ptype" = "SecureString" ]; then
    if [ -z "$keyid" ] || [ "$keyid" = "null" ]; then
      echo "  SECURESTRING_NO_KMS_KEY: using default (check KMS)" >> "$REPORT_FILE"
      send_slack_alert "SSM Alert: SecureString parameter $name has no explicit KMS KeyId"
    else
      echo "  SecureString KMS Key: $keyid" >> "$REPORT_FILE"
    fi
  fi

  # parameter policies (if any)
  if aws ssm get-parameter-history --name "$name" --output json >/dev/null 2>&1; then
    # note: policies are optional; we avoid reading values
    # check if parameter has a policy
    policy=$(aws ssm list-tags-for-resource --resource-type "Parameter" --resource-id "$name" --output json 2>/dev/null || echo '{}')
    if [ -n "$(echo "$policy" | jq -r '.TagList // empty')" ]; then
      echo "  Tags: $(echo "$policy" | jq -r '.TagList[]? | "\(.Key)=\(.Value)"' | paste -sd ", " -)" >> "$REPORT_FILE"
    fi
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  # paginate through parameters
  next_token=""
  while :; do
    if [ -z "$next_token" ]; then
      out=$(aws ssm describe-parameters --output json 2>/dev/null || echo '{"Parameters":[]}')
    else
      out=$(aws ssm describe-parameters --output json --next-token "$next_token" 2>/dev/null || echo '{"Parameters":[]}')
    fi

    echo "$out" | jq -r '.Parameters[]?.Name' | while read -r n; do
      check_parameter "$n"
    done

    next_token=$(echo "$out" | jq -r '.NextToken // empty')
    if [ -z "$next_token" ]; then
      break
    fi
  done

  log_message "SSM Parameter audit written to $REPORT_FILE"
}

main "$@"
