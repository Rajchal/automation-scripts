#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-acm-certificate-auditor.log"
REPORT_FILE="/tmp/acm-certificate-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
EXPIRY_DAYS="${ACM_EXPIRY_DAYS:-30}"
MAX_RESULTS="${ACM_MAX_RESULTS:-100}"
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
  echo "ACM Certificate Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Expiry threshold (days): $EXPIRY_DAYS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

iso_to_epoch() {
  date -d "$1" +%s 2>/dev/null || echo 0
}

main() {
  write_header

  certs_json=$(aws acm list-certificates --region "$REGION" --max-items "$MAX_RESULTS" --output json 2>/dev/null || echo '{"CertificateSummaryList":[]}')
  arns=$(echo "$certs_json" | jq -r '.CertificateSummaryList[]?.CertificateArn')

  if [ -z "$arns" ]; then
    echo "No ACM certificates found." >> "$REPORT_FILE"
    log_message "No ACM certificates in region $REGION"
    exit 0
  fi

  total=0
  expiring=0

  for arn in $arns; do
    total=$((total+1))
    detail=$(aws acm describe-certificate --certificate-arn "$arn" --region "$REGION" --output json 2>/dev/null || echo '{}')
    domain=$(echo "$detail" | jq -r '.Certificate.DomainName // "<unknown>"')
    status=$(echo "$detail" | jq -r '.Certificate.Status // "<unknown>"')
    not_after=$(echo "$detail" | jq -r '.Certificate.NotAfter // empty')
    not_before=$(echo "$detail" | jq -r '.Certificate.NotBefore // empty')
    validations=$(echo "$detail" | jq -c '.Certificate.DomainValidationOptions // []')

    echo "Certificate: $arn" >> "$REPORT_FILE"
    echo "Domain: $domain" >> "$REPORT_FILE"
    echo "Status: $status" >> "$REPORT_FILE"
    echo "NotBefore: ${not_before}" >> "$REPORT_FILE"
    echo "NotAfter: ${not_after}" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    if [ -n "$not_after" ] && [ "$not_after" != "null" ]; then
      not_after_epoch=$(iso_to_epoch "$not_after")
      now_epoch=$(date +%s)
      days_left=$(( (not_after_epoch - now_epoch) / 86400 ))
      if [ "$days_left" -le "$EXPIRY_DAYS" ]; then
        echo "ALERT: Certificate $arn for $domain expires in ${days_left} days" >> "$REPORT_FILE"
        send_slack_alert "ACM Alert: Certificate for $domain (arn=$arn) expires in ${days_left} days (status=$status)"
        expiring=$((expiring+1))
      fi
    fi

    # Check domain validation statuses
    echo "$validations" | jq -c '.[]' | while read -r v; do
      name=$(echo "$v" | jq -r '.DomainName // .DomainName')
      val_status=$(echo "$v" | jq -r '.ValidationStatus // "<unknown>"')
      method=$(echo "$v" | jq -r '.ValidationMethod // "<unknown>"')
      if [ "$val_status" != "SUCCESS" ]; then
        echo "Domain validation issue: $name method=$method status=$val_status" >> "$REPORT_FILE"
        send_slack_alert "ACM Alert: Certificate $arn domain $name validation status=$val_status (method=$method)"
      fi
    done
  done

  echo "Summary: total=$total, expiring_within_${EXPIRY_DAYS}d=$expiring" >> "$REPORT_FILE"
  log_message "ACM report written to $REPORT_FILE (total=$total, expiring=${expiring})"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-acm-certificate-auditor.log"
REPORT_FILE="/tmp/acm-certificate-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
EXPIRY_DAYS_THRESHOLD="${ACM_EXPIRY_DAYS:-30}"
MAX_RESULTS="${ACM_MAX_RESULTS:-100}"
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
  echo "ACM Certificate Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Expiry threshold (days): $EXPIRY_DAYS_THRESHOLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

days_until() {
  # arg: RFC3339 date
  target=$1
  if [ -z "$target" ] || [ "$target" = "null" ]; then
    echo 99999
    return
  fi
  now=$(date -u +%s)
  then_epoch=$(date -d "$target" +%s 2>/dev/null || echo 0)
  if [ "$then_epoch" -le 0 ]; then
    echo 99999
    return
  fi
  echo $(( (then_epoch - now) / 86400 ))
}

main() {
  write_header

  certs_json=$(aws acm list-certificates --max-items "$MAX_RESULTS" --region "$REGION" --output json 2>/dev/null || echo '{"CertificateSummaryList":[]}')
  ids=$(echo "$certs_json" | jq -r '.CertificateSummaryList[]?.CertificateArn')

  if [ -z "$ids" ]; then
    echo "No ACM certificates found." >> "$REPORT_FILE"
    log_message "No ACM certificates in region $REGION"
    exit 0
  fi

  total=0
  alerts=0

  for arn in $ids; do
    total=$((total+1))
    detail=$(aws acm describe-certificate --certificate-arn "$arn" --region "$REGION" --output json 2>/dev/null || echo '{}')
    domain=$(echo "$detail" | jq -r '.Certificate.DomainName // "<unknown>"')
    not_after=$(echo "$detail" | jq -r '.Certificate.NotAfter // empty')
    status=$(echo "$detail" | jq -r '.Certificate.Status // "<unknown>"')
    type=$(echo "$detail" | jq -r '.Certificate.Type // "<unknown>"')
    validation=$(echo "$detail" | jq -c '.Certificate.DomainValidationOptions // []')

    days=$(days_until "$not_after")

    echo "Certificate: $arn" >> "$REPORT_FILE"
    echo "Domain: $domain" >> "$REPORT_FILE"
    echo "Type: $type" >> "$REPORT_FILE"
    echo "Status: $status" >> "$REPORT_FILE"
    echo "Expires: ${not_after:-<unknown>} (in ${days} days)" >> "$REPORT_FILE"

    if [ -n "$validation" ] && [ "$validation" != "[]" ]; then
      echo "$validation" | jq -r '.[] | "Validation: domain=" + (.DomainName // "") + " status=" + (.ValidationStatus // "")' >> "$REPORT_FILE"
    fi

    echo "" >> "$REPORT_FILE"

    # Alert conditions
    if [ "$days" -le "$EXPIRY_DAYS_THRESHOLD" ]; then
      send_slack_alert "ACM Alert: Certificate for $domain expires in ${days} days (ARN: $arn)."
      alerts=$((alerts+1))
    fi

    # Check validation statuses for visible failures
    bad_validation=$(echo "$detail" | jq -r '.Certificate.DomainValidationOptions[]?.ValidationStatus // empty' | grep -E "FAILED|PENDING_VALIDATION" || true)
    if [ -n "$bad_validation" ]; then
      send_slack_alert "ACM Alert: Certificate $arn domain validation statuses: $(echo "$bad_validation" | tr '\n' ',' )"
      alerts=$((alerts+1))
    fi

    if [ "$status" = "EXPIRED" ] || [ "$status" = "INACTIVE" ]; then
      send_slack_alert "ACM Alert: Certificate $arn has status $status for domain $domain"
      alerts=$((alerts+1))
    fi
  done

  echo "Summary: total_certificates=$total, alerts=$alerts" >> "$REPORT_FILE"
  log_message "ACM report written to $REPORT_FILE (total=$total, alerts=$alerts)"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-acm-certificate-auditor.log"
REPORT_FILE="/tmp/acm-certificate-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
EXPIRY_DAYS="${ACM_EXPIRY_DAYS:-30}"
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
  echo "ACM Certificate Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Expiry threshold (days): $EXPIRY_DAYS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  certs=$(aws acm list-certificates --region "$REGION" --output json 2>/dev/null || echo '{"CertificateSummaryList":[]}')
  ids=$(echo "$certs" | jq -r '.CertificateSummaryList[]?.CertificateArn')

  if [ -z "$ids" ]; then
    echo "No ACM certificates found." >> "$REPORT_FILE"
    log_message "No ACM certificates in region $REGION"
    exit 0
  fi

  now_epoch=$(date -u +%s)
  warn_epoch=$((now_epoch + EXPIRY_DAYS * 24 * 3600))

  for arn in $ids; do
    detail=$(aws acm describe-certificate --certificate-arn "$arn" --region "$REGION" --output json 2>/dev/null || echo '{}')
    domain=$(echo "$detail" | jq -r '.Certificate.DomainName // "<unknown>"')
    not_after=$(echo "$detail" | jq -r '.Certificate.NotAfter // empty')
    status=$(echo "$detail" | jq -r '.Certificate.Status // "<unknown>"')
    domain_validation=$(echo "$detail" | jq -r '.Certificate.DomainValidationOptions[]? | "\(.DomainName):\(.ValidationStatus)"' | paste -sd"," -)

    not_after_epoch=0
    if [ -n "$not_after" ]; then
      not_after_epoch=$(date -d "$not_after" +%s 2>/dev/null || echo 0)
    fi

    echo "Cert: $arn" >> "$REPORT_FILE"
    echo "Domain: $domain" >> "$REPORT_FILE"
    echo "Status: $status" >> "$REPORT_FILE"
    echo "NotAfter: $not_after" >> "$REPORT_FILE"
    echo "DomainValidation: $domain_validation" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    if [ "$not_after_epoch" -ne 0 ] && [ "$not_after_epoch" -le "$warn_epoch" ]; then
      days_left=$(( (not_after_epoch - now_epoch) / 86400 ))
      send_slack_alert "ACM Alert: Certificate $domain ($arn) expires in ${days_left} days (status=$status)."
    fi

    if echo "$domain_validation" | grep -q -E 'PENDING|FAILED'; then
      send_slack_alert "ACM Alert: Certificate $domain ($arn) has domain validation issues: $domain_validation"
    fi
  done

  log_message "ACM auditor written to $REPORT_FILE"
}

main "$@"
#!/bin/bash

################################################################################
# AWS ACM Certificate Auditor
# Audits ACM certificates for expiration, validation status, and usage (ELB/CloudFront)
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/acm-certificate-audit-$(date +%s).txt"
LOG_FILE="/var/log/acm-certificate-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EXPIRY_WARN_DAYS="${EXPIRY_WARN_DAYS:-30}"

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

# API wrappers
list_certificates() {
  aws acm list-certificates \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_certificate() {
  local arn="$1"
  aws acm describe-certificate \
    --region "${REGION}" \
    --certificate-arn "${arn}" \
    --output json 2>/dev/null || echo '{}'
}

list_distributions() {
  aws cloudfront list-distributions --output json 2>/dev/null || echo '{}'
}

get_elbv2_listeners() {
  local region="$1"
  aws elbv2 describe-listeners --region "${region}" --output json 2>/dev/null || echo '{}'
}

list_elbv2_load_balancers() {
  local region="$1"
  aws elbv2 describe-load-balancers --region "${region}" --output json 2>/dev/null || echo '{}'
}

list_tags_for_certificate() {
  local arn="$1"
  aws acm list-tags-for-certificate --certificate-arn "${arn}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS ACM Certificate Audit Report"
    echo "================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Expiry Warn (days): ${EXPIRY_WARN_DAYS}"
    echo ""
  } > "${OUTPUT_FILE}"
}

find_cloudfront_usage() {
  local arn="$1"
  local used=0
  local dists
  dists=$(list_distributions)
  echo "${dists}" | jq -c '.DistributionList.Items[]? | {Id: .Id, Cert: .ViewerCertificate.ACMCertificateArn, DomainName: .DomainName}' 2>/dev/null | while read -r item; do
    local cert
    cert=$(echo "${item}" | jq_safe '.Cert')
    if [[ "${cert}" == "${arn}" ]]; then
      used=1
      echo "${item}"
      return 0
    fi
  done >/dev/null || true
  # return whether used by cloudfront (0/1) via stdout
  if [[ ${used} -eq 1 ]]; then
    echo "true"
  else
    echo "false"
  fi
}

find_elb_usage() {
  local arn="$1"
  local region="$2"
  local used=false
  # iterate listeners per load balancer
  local lbs listeners
  lbs=$(list_elbv2_load_balancers "${region}")
  echo "${lbs}" | jq -c '.LoadBalancers[]? | {LoadBalancerArn:.LoadBalancerArn,LoadBalancerName:.LoadBalancerName}' 2>/dev/null | while read -r lb; do
    local lb_arn lb_name
    lb_arn=$(echo "${lb}" | jq_safe '.LoadBalancerArn')
    lb_name=$(echo "${lb}" | jq_safe '.LoadBalancerName')
    listeners=$(aws elbv2 describe-listeners --load-balancer-arn "${lb_arn}" --region "${region}" --output json 2>/dev/null || echo '{}')
    echo "${listeners}" | jq -c '.Listeners[]? | {ListenerArn:.ListenerArn, Certificates:.Certificates}' 2>/dev/null | while read -r l; do
      local certs
      certs=$(echo "${l}" | jq -c '.Certificates' 2>/dev/null)
      if echo "${certs}" | jq -e --arg arn "${arn}" '.[]? | select(.CertificateArn == $arn)' >/dev/null 2>&1; then
        used=true
        echo "true"
        return 0
      fi
    done >/dev/null || true
  done >/dev/null || true
  if [[ "${used}" == "true" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

audit_certificates() {
  log_message INFO "Auditing ACM certificates"
  {
    echo "=== ACM CERTIFICATES ==="
  } >> "${OUTPUT_FILE}"

  local certs_json
  certs_json=$(list_certificates)

  local total=0 expiring=0 expired=0 invalid=0 unused=0 issued=0 imported=0

  echo "${certs_json}" | jq -c '.CertificateSummaryList[]?' 2>/dev/null | while read -r cert; do
    ((total++))
    local cert_arn domain type
    cert_arn=$(echo "${cert}" | jq_safe '.CertificateArn')
    domain=$(echo "${cert}" | jq_safe '.DomainName')
    type=$(echo "${cert}" | jq_safe '.Type')

    local desc
    desc=$(describe_certificate "${cert_arn}")
    local not_after status in_use_by_lb in_use_by_cf validation
    not_after=$(echo "${desc}" | jq_safe '.Certificate.NotAfter')
    status=$(echo "${desc}" | jq_safe '.Certificate.Status')
    validation=$(echo "${desc}" | jq_safe '.Certificate.DomainValidationOptions[]?.ValidationStatus' | tr '\n' ',' | sed 's/,$//')

    # Days until expiry
    local days_left=0
    if [[ -n "${not_after}" && "${not_after}" != "null" ]]; then
      local not_after_epoch now_epoch
      not_after_epoch=$(date -d "${not_after}" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      days_left=$(( (not_after_epoch - now_epoch) / 86400 ))
    fi

    {
      echo "Certificate: ${domain}"
      echo "  ARN: ${cert_arn}"
      echo "  Type: ${type}"
      echo "  Status: ${status}"
      echo "  Validation: ${validation}"
      echo "  Expires In: ${days_left} days"
    } >> "${OUTPUT_FILE}"

    if [[ "${status}" != "ISSUED" ]]; then
      ((invalid++))
      echo "  WARNING: Certificate status is ${status}" >> "${OUTPUT_FILE}"
    fi

    if (( days_left <= 0 )); then
      ((expired++))
      echo "  WARNING: Certificate expired or expires today" >> "${OUTPUT_FILE}"
    elif (( days_left <= EXPIRY_WARN_DAYS )); then
      ((expiring++))
      echo "  WARNING: Certificate expiring within ${EXPIRY_WARN_DAYS} days" >> "${OUTPUT_FILE}"
    fi

    # Check usage by CloudFront
    local cf_used
    cf_used=$(find_cloudfront_usage "${cert_arn}")
    if [[ "${cf_used}" == "true" ]]; then
      in_use_by_cf=true
      echo "  Used By: CloudFront" >> "${OUTPUT_FILE}"
    else
      in_use_by_cf=false
    fi

    # Check usage by ELBv2 across regions (scan a few common regions)
    local regions=("us-east-1" "us-west-2" "eu-west-1" "ap-southeast-1")
    local elb_used=false
    for r in "${regions[@]}"; do
      local used
      used=$(find_elb_usage "${cert_arn}" "${r}")
      if [[ "${used}" == "true" ]]; then
        elb_used=true
        echo "  Used By: ELB (region: ${r})" >> "${OUTPUT_FILE}"
      fi
    done

    if [[ "${cf_used}" != "true" && "${elb_used}" != "true" ]]; then
      ((unused++))
      echo "  INFO: Certificate not found in CloudFront or ELB listeners (may be unused)" >> "${OUTPUT_FILE}"
    fi

    # Type counts
    if [[ "${type}" == "AMAZON_ISSUED" || "${type}" == "AMAZON" ]]; then
      ((issued++))
    else
      ((imported++))
    fi

    # Tags
    local tags
    tags=$(list_tags_for_certificate "${cert_arn}")
    if echo "${tags}" | jq -e '.Tags | length > 0' >/dev/null 2>&1; then
      echo "  Tags: $(echo "${tags}" | jq -c '.Tags')" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Certificate Summary:"
    echo "  Total Certificates: ${total}"
    echo "  Issued (Amazon): ${issued}"
    echo "  Imported: ${imported}"
    echo "  Expiring (<= ${EXPIRY_WARN_DAYS}d): ${expiring}"
    echo "  Expired: ${expired}"
    echo "  Invalid/Not Issued: ${invalid}"
    echo "  Potentially Unused: ${unused}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local expiring="$2"; local expired="$3"; local unused="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  (( expired > 0 )) && color="danger"
  (( expiring > 0 && expired == 0 )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS ACM Certificate Audit Report",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Total Certs", "value": "${total}", "short": true},
        {"title": "Expiring", "value": "${expiring}", "short": true},
        {"title": "Expired", "value": "${expired}", "short": true},
        {"title": "Possibly Unused", "value": "${unused}", "short": true},
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Timestamp", "value": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "short": false}
      ]
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

main() {
  log_message INFO "Starting ACM certificate audit"
  write_header
  audit_certificates
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total expiring expired unused
  total=$(grep "Total Certificates:" "${OUTPUT_FILE}" | awk '{print $NF}')
  expiring=$(grep "Expiring (<= " -n "${OUTPUT_FILE}" | awk -F: '{print $2}' | awk '{print $NF}' 2>/dev/null || true)
  if [[ -z "${expiring}" ]]; then expiring=0; fi
  expired=$(grep "Expired:" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  unused=$(grep "Potentially Unused:" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  send_slack_alert "${total}" "${expiring}" "${expired}" "${unused}"
  cat "${OUTPUT_FILE}"
}

main "$@"
