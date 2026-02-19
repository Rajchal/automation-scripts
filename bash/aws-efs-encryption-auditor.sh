#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-efs-encryption-auditor.sh"
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
AWS EFS Encryption Auditor
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

Findings:
EOF
}

check_filesystem() {
  local fs_id="$1"
  local fs_json
  fs_json=$(aws efs describe-file-systems --file-system-id "$fs_id" --output json 2>/dev/null || echo '{}')
  local encrypted
  encrypted=$(echo "$fs_json" | jq -r '.FileSystems[0].Encrypted // false')
  local kms_key
  kms_key=$(echo "$fs_json" | jq -r '.FileSystems[0].KmsKeyId // empty')
  local name
  name=$(echo "$fs_json" | jq -r '.FileSystems[0].Name // "<unknown>"')

  if [ "$encrypted" != "true" ]; then
    echo "FileSystem: $fs_id (name=$name) - Encryption DISABLED" >> "$REPORT_FILE"
    return 0
  fi
  if [ -z "$kms_key" ]; then
    echo "FileSystem: $fs_id (name=$name) - Encrypted but no KMS key id recorded (uses AWS-managed?)" >> "$REPORT_FILE"
    return 0
  fi
  return 1
}

main() {
  write_header
  log_message "Starting EFS encryption auditor"

  local fs_list
  fs_list=$(aws efs describe-file-systems --output json 2>/dev/null || echo '{"FileSystems":[]}')
  local ids
  ids=$(echo "$fs_list" | jq -r '.FileSystems[]?.FileSystemId') || true
  if [ -z "$ids" ]; then
    log_message "No EFS file systems found or AWS CLI failed"
    rm -f "$REPORT_FILE"
    exit 0
  fi

  local any=0
  for fs in $ids; do
    if check_filesystem "$fs"; then
      any=1
      log_message "Findings for EFS $fs"
    fi
  done

  if [ "$any" -eq 1 ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "EFS encryption auditor found issues. See $REPORT_FILE on host."
  else
    log_message "No EFS encryption issues found"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"
