#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-cloudfront-distribution-auditor.log"
REPORT_FILE="/tmp/cloudfront-distribution-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
MIN_TLS_ALLOWED="${CLOUDFRONT_MIN_TLS:-TLSv1.2_2019}"

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
  echo "CloudFront Distribution Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (for API calls): $REGION" >> "$REPORT_FILE"
  echo "Minimum TLS required: $MIN_TLS_ALLOWED" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_distribution() {
  local id="$1"
  local dist_json
  dist_json=$(aws cloudfront get-distribution --id "$id" --output json 2>/dev/null || echo '{}')

  if [ -z "$dist_json" ] || [ "$dist_json" = "{}" ]; then
    echo "Distribution $id: unable to fetch details" >> "$REPORT_FILE"
    return
  fi

  enabled=$(echo "$dist_json" | jq -r '.Distribution.DistributionConfig.Enabled')
  logging=$(echo "$dist_json" | jq -r '.Distribution.DistributionConfig.Logging.Enabled')
  viewer_cert=$(echo "$dist_json" | jq -r '.Distribution.DistributionConfig.ViewerCertificate.MinimumProtocolVersion // "<none>"')
  web_acl_id=$(echo "$dist_json" | jq -r '.Distribution.DistributionConfig.WebACLId // empty')
  aliases=$(echo "$dist_json" | jq -r '.Distribution.DistributionConfig.Aliases.Items | join(",") // ""')

  echo "Distribution: $id" >> "$REPORT_FILE"
  echo "Enabled: $enabled" >> "$REPORT_FILE"
  echo "Logging enabled: ${logging:-false}" >> "$REPORT_FILE"
  echo "MinimumProtocolVersion: ${viewer_cert}" >> "$REPORT_FILE"
  echo "WebACLId: ${web_acl_id:-<none>}" >> "$REPORT_FILE"
  echo "Aliases: ${aliases}" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  if [ "${enabled}" != "true" ]; then
    send_slack_alert "CloudFront Alert: Distribution $id is disabled."
  fi

  if [ "${logging}" != "true" ]; then
    send_slack_alert "CloudFront Alert: Distribution $id has logging disabled."
  fi

  # Check TLS policy: ensure configured minimum protocol contains the required substring
  if [ "$viewer_cert" = "<none>" ] || [[ "$viewer_cert" < "$MIN_TLS_ALLOWED" ]]; then
    # Fallback: if viewer_cert doesn't contain TLSv1.2, flag it
    if [[ "$viewer_cert" != *"TLSv1.2"* ]]; then
      send_slack_alert "CloudFront Alert: Distribution $id uses insecure TLS policy ($viewer_cert). Require $MIN_TLS_ALLOWED or higher."
    fi
  fi

  if [ -z "$web_acl_id" ] || [ "$web_acl_id" = "" ] || [ "$web_acl_id" = "null" ]; then
    send_slack_alert "CloudFront Alert: Distribution $id has no WAF (WebACL) associated."
  fi
}

main() {
  write_header

  dlist=$(aws cloudfront list-distributions --output json 2>/dev/null || echo '{"DistributionList":{"Items":[]}}')
  ids=$(echo "$dlist" | jq -r '.DistributionList.Items[]?.Id')

  if [ -z "$ids" ]; then
    echo "No CloudFront distributions found." >> "$REPORT_FILE"
    log_message "No CloudFront distributions"
    exit 0
  fi

  echo "Checking distributions..." >> "$REPORT_FILE"
  for id in $ids; do
    check_distribution "$id"
  done

  log_message "CloudFront auditor written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-cloudfront-distribution-auditor.log"
REPORT_FILE="/tmp/cloudfront-distribution-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
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
  echo "CloudFront Distribution Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region (for reference): $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_distribution() {
  local id="$1"
  dist_json=$(aws cloudfront get-distribution --id "$id" --output json 2>/dev/null || echo '{}')
  config=$(echo "$dist_json" | jq -r '.Distribution.DistributionConfig // {}')
  enabled=$(echo "$config" | jq -r '.Enabled // false')
  logging=$(echo "$config" | jq -r '.Logging.Enabled // false')
  min_tls=$(echo "$config" | jq -r '.ViewerCertificate.MinimumProtocolVersion // ""')
  acm=$(echo "$config" | jq -r '.ViewerCertificate.ACMCertificateArn // empty')
  default_root=$(echo "$config" | jq -r '.DefaultRootObject // ""')
  web_acl=$(echo "$config" | jq -r '.WebACLId // ""')

  summary="Distribution $id: enabled=$enabled logging=$logging min_tls=$min_tls acm=${acm:-none} default_root=${default_root:-<none>} web_acl=${web_acl:-<none>}"
  echo "$summary" >> "$REPORT_FILE"

  # Alerts
  if [ "$enabled" != "true" ]; then
    send_slack_alert "CloudFront ALERT: Distribution $id is DISABLED. $summary"
  fi

  if [ "$logging" != "true" ]; then
    send_slack_alert "CloudFront ALERT: Distribution $id has logging disabled. $summary"
  fi

  # TLS check: prefer TLSv1.2_2019 or higher; warn if empty or lower
  if [ -z "$min_tls" ] || [[ "$min_tls" =~ TLSv1.0|TLSv1.1 ]]; then
    send_slack_alert "CloudFront ALERT: Distribution $id has weak/unspecified TLS protocol ($min_tls). $summary"
  fi

  # WAF: optional but alert if missing
  if [ -z "$web_acl" ] || [ "$web_acl" = "" ] || [ "$web_acl" = "null" ]; then
    send_slack_alert "CloudFront NOTICE: Distribution $id has no associated WAF WebACL. $summary"
  fi
}

main() {
  write_header

  dlist=$(aws cloudfront list-distributions --output json 2>/dev/null || echo '{"DistributionList":{"Items":[]}}')
  ids=$(echo "$dlist" | jq -r '.DistributionList.Items[]?.Id')

  if [ -z "$ids" ]; then
    echo "No CloudFront distributions found." >> "$REPORT_FILE"
    log_message "No CloudFront distributions found"
    exit 0
  fi

  echo "Found distributions:" >> "$REPORT_FILE"
  echo "$ids" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  for id in $ids; do
    check_distribution "$id"
    echo "" >> "$REPORT_FILE"
  done

  log_message "CloudFront auditor report written to $REPORT_FILE"
}

main "$@"
