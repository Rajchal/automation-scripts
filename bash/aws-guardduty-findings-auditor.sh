#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-guardduty-findings-auditor.log"
REPORT_FILE="/tmp/guardduty-findings-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
SEVERITY_THRESHOLD="${GUARDDUTY_SEVERITY_THRESHOLD:-4.0}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS GuardDuty Findings Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Severity threshold: $SEVERITY_THRESHOLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_detector() {
  local det="$1"
  echo "Detector: $det" >> "$REPORT_FILE"
  finds=$(aws guardduty list-findings --detector-id "$det" --output json 2>/dev/null || echo '{"FindingIds":[]}')
  echo "$finds" | jq -c '.FindingIds[]? // empty' | while read -r fid; do
    fjson=$(aws guardduty get-findings --detector-id "$det" --finding-ids "$fid" --output json 2>/dev/null || echo '{}')
    f=$(echo "$fjson" | jq -c '.Findings[]? // empty')
    title=$(echo "$f" | jq -r '.Title // ""')
    sev=$(echo "$f" | jq -r '.Severity // 0')
    resource=$(echo "$f" | jq -r '.Resource | tostring')
    echo "  Finding: $fid severity=$sev title=$title" >> "$REPORT_FILE"
    if (( $(echo "$sev >= $SEVERITY_THRESHOLD" | bc -l) )); then
      send_slack_alert "GuardDuty Alert: $title (severity=$sev) DetId=$det Finding=$fid"
    fi
  done
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header
  dets=$(aws guardduty list-detectors --output json 2>/dev/null || echo '{"DetectorIds":[]}')
  echo "$dets" | jq -c '.DetectorIds[]? // empty' | while read -r d; do
    check_detector "$d"
  done
  log_message "GuardDuty audit written to $REPORT_FILE"
}

main "$@"
