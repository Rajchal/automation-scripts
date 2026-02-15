#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-sqs-queue-auditor.sh"
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
AWS SQS Queues Auditor
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

Findings:
EOF
}

check_policy_for_public() {
  local policy_json="$1"
  echo "$policy_json" | jq -e '
    .Statement // [] |
    (if type=="object" then [.] else . end) |
    map(select(.Effect=="Allow")) |
    map(select(
      (.Principal=="*") or
      (.Principal.AWS=="*") or
      (.Principal==null)
    )) | length > 0
  ' >/dev/null 2>&1
}

check_queue() {
  local url="$1"
  local attrs
  attrs=$(aws sqs get-queue-attributes --queue-url "$url" --attribute-names All --output json 2>/dev/null) || return 0

  local name
  name=$(echo "$attrs" | jq -r '.Attributes.QueueArn' | awk -F: '{print $NF}')

  local kms
  kms=$(echo "$attrs" | jq -r '.Attributes.KmsMasterKeyId // empty')
  local redrive
  redrive=$(echo "$attrs" | jq -r '.Attributes.RedrivePolicy // empty')
  local policy
  policy=$(echo "$attrs" | jq -r '.Attributes.Policy // empty')

  local found=0
  echo "Queue: $name" >> "$REPORT_FILE"
  if [ -z "$kms" ]; then
    echo "  - Missing server-side KMS encryption (KmsMasterKeyId)" >> "$REPORT_FILE"
    found=1
  fi
  if [ -z "$redrive" ]; then
    echo "  - No dead-letter queue / redrive policy configured" >> "$REPORT_FILE"
    found=1
  fi
  if [ -n "$policy" ]; then
    if check_policy_for_public "$policy"; then
      echo "  - Queue policy allows public or wildcard principal" >> "$REPORT_FILE"
      found=1
    fi
  fi

  if [ "$found" -eq 1 ]; then
    echo >> "$REPORT_FILE"
    return 0
  fi
  # No findings for this queue; remove the header line we wrote
  sed -i "\$ d" "$REPORT_FILE" || true
  return 1
}

main() {
  write_header
  log_message "Starting SQS queues auditor"

  local queues
  queues=$(aws sqs list-queues --output json 2>/dev/null | jq -r '.QueueUrls[]?') || true
  if [ -z "$queues" ]; then
    log_message "No queues found or AWS CLI failed"
    rm -f "$REPORT_FILE"
    exit 0
  fi

  local any=0
  for q in $queues; do
    if check_queue "$q"; then
      any=1
      log_message "Findings for queue $q"
    fi
  done

  if [ "$any" -eq 1 ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "SQS auditor found issues. See $REPORT_FILE on host."
  else
    log_message "No issues found for SQS queues"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"
