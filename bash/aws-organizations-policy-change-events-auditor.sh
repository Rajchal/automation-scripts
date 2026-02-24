#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-policy-change-events-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-policy-change-events-audit"
LOG_FILE="/var/log/aws-organizations-policy-change-events-auditor.log"

write_header() {
  mkdir -p "${REPORT_DIR}"
  echo "AWS Organizations Policy Change Events Auditor" > "${REPORT_DIR}/header.txt"
  echo "Run at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "${REPORT_DIR}/header.txt"
}

log_message() {
  local level="$1"; shift
  local msg="$*"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

send_slack_alert() {
  if [[ -z "${SLACK_WEBHOOK:-}" ]]; then
    return 0
  fi
  local payload
  payload=$(jq -n --arg t "$1" '{text:$t}')
  curl -s -S -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
}

check_tools() {
  for cmd in aws jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_message ERROR "$cmd not found; aborting"
      exit 2
    fi
  done
}

audit_change_events() {
  log_message INFO "Looking up CloudTrail events for Organizations policy changes"
  out="${REPORT_DIR}/policy_change_events.tsv"
  echo -e "EventId\tEventName\tEventTime\tUsername\tResources" > "$out"

  events=("CreatePolicy" "UpdatePolicy" "DeletePolicy" "AttachPolicy" "DetachPolicy")
  for ev in "${events[@]}"; do
    log_message INFO "Lookup events for: $ev"
    ev_json=$(aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue="$ev" --max-results 50 2>/dev/null || echo '{}')
    cnt=$(echo "$ev_json" | jq '.Events | length')
    if [[ "$cnt" -eq 0 ]]; then
      log_message INFO "No recent CloudTrail events for $ev"
      continue
    fi

    echo "$ev_json" | jq -r '.Events[]? | [ .EventId, .EventName, (.EventTime // ""), (.Username // "(no-user)"), ((.Resources // []) | map((.ResourceType + ":" + (.ResourceName // "(no-name)"))) | join(",")) ] | @tsv' >> "$out" 2>/dev/null || true
    # save raw events for inspection
    echo "$ev_json" > "${REPORT_DIR}/${ev}_events.json"
  done
}

finalize() {
  log_message INFO "Policy change events audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations policy change-events audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_tools
  audit_change_events
  finalize
}

main "$@"
