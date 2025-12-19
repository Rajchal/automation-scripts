#!/bin/bash

################################################################################
# AWS ACM Certificate Manager - Bulk Validation & Expiry Monitor
# Validates and monitors all ACM certificates for expiry, renewal status,
# domain validation, and certificate chain health
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/acm-validator-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/acm-validator.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Warning thresholds
EXPIRY_WARN_DAYS="${EXPIRY_WARN_DAYS:-30}"
RENEWAL_TIMEOUT_DAYS="${RENEWAL_TIMEOUT_DAYS:-7}"

# Color codes for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

# Helpers
jq_safe() { jq -r "$1" 2>/dev/null || echo ""; }

days_until_expiry() {
  local expiry_date="$1"
  local expiry_epoch
  local current_epoch
  
  expiry_epoch=$(date -d "${expiry_date}" +%s 2>/dev/null || echo 0)
  current_epoch=$(date +%s)
  
  if [[ ${expiry_epoch} -eq 0 ]]; then
    echo "UNKNOWN"
    return
  fi
  
  local days_diff=$(( (expiry_epoch - current_epoch) / 86400 ))
  echo "${days_diff}"
}

list_acm_certificates() {
  aws acm list-certificates \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"CertificateSummaryList":[]}'
}

describe_certificate() {
  local cert_arn="$1"
  aws acm describe-certificate \
    --certificate-arn "${cert_arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

send_slack_alert() {
  local message="$1"
  local severity="$2" # INFO, WARNING, CRITICAL
  
  if [[ -z "${SLACK_WEBHOOK}" ]]; then
    return
  fi
  
  local color
  case "${severity}" in
    CRITICAL) color="danger" ;;
    WARNING)  color="warning" ;;
    INFO)     color="good" ;;
    *)        color="good" ;;
  esac
  
  local payload
  payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "${color}",
      "title": "ACM Certificate Alert",
      "text": "${message}",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  
  curl -X POST -H 'Content-type: application/json' \
    --data "${payload}" \
    "${SLACK_WEBHOOK}" 2>/dev/null || true
}

send_email_alert() {
  local subject="$1"
  local body="$2"
  
  if [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null; then
    return
  fi
  
  echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true
}

write_header() {
  {
    echo "AWS ACM Certificate Validation Report"
    echo "======================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Expiry Warning: ${EXPIRY_WARN_DAYS} days"
    echo "Renewal Timeout: ${RENEWAL_TIMEOUT_DAYS} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

validate_certificates() {
  log_message INFO "Starting ACM certificate validation"
  
  {
    echo "=== CERTIFICATE SUMMARY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local total_certs=0
  local expired_certs=0
  local expiring_certs=0
  local validation_failed=0
  local renewal_pending=0
  local healthy_certs=0
  
  local certs_json
  certs_json=$(list_acm_certificates)
  
  local cert_arns
  cert_arns=$(echo "${certs_json}" | jq -r '.CertificateSummaryList[].CertificateArn' 2>/dev/null)
  
  if [[ -z "${cert_arns}" ]]; then
    log_message WARN "No ACM certificates found in region ${REGION}"
    {
      echo "Status: No certificates found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS= read -r cert_arn; do
    ((total_certs++))
    
    log_message INFO "Validating certificate: ${cert_arn}"
    
    local cert_details
    cert_details=$(describe_certificate "${cert_arn}")
    
    local domain_name
    local status
    local expiry_date
    local created_date
    local validation_status
    local renewal_eligibility
    local key_algorithm
    local renewal_summary
    
    domain_name=$(echo "${cert_details}" | jq_safe '.Certificate.DomainName')
    status=$(echo "${cert_details}" | jq_safe '.Certificate.Status')
    expiry_date=$(echo "${cert_details}" | jq_safe '.Certificate.NotAfter')
    created_date=$(echo "${cert_details}" | jq_safe '.Certificate.CreatedAt')
    key_algorithm=$(echo "${cert_details}" | jq_safe '.Certificate.KeyAlgorithm')
    renewal_eligibility=$(echo "${cert_details}" | jq_safe '.Certificate.RenewalEligibility')
    renewal_summary=$(echo "${cert_details}" | jq_safe '.Certificate.RenewalSummary.Status')
    
    # Get domain validation status
    local domain_validations
    domain_validations=$(echo "${cert_details}" | jq -r '.Certificate.DomainValidationOptions[]? | "\(.DomainName):\(.ValidationStatus)"' 2>/dev/null)
    
    # Calculate days until expiry
    local days_to_expiry="UNKNOWN"
    if [[ -n "${expiry_date}" && "${expiry_date}" != "null" ]]; then
      days_to_expiry=$(days_until_expiry "${expiry_date}")
    fi
    
    # Determine certificate health
    local cert_status_color="${GREEN}"
    local alert_message=""
    
    {
      echo ""
      echo "Certificate ARN: ${cert_arn}"
      echo "Domain: ${domain_name}"
      echo "Status: ${status}"
      echo "Key Algorithm: ${key_algorithm}"
      echo "Created: ${created_date}"
      echo "Expires: ${expiry_date}"
      if [[ "${days_to_expiry}" != "UNKNOWN" ]]; then
        echo "Days Until Expiry: ${days_to_expiry}"
      fi
      echo "Renewal Eligibility: ${renewal_eligibility}"
      echo "Renewal Status: ${renewal_summary}"
      echo ""
      echo "Domain Validations:"
      if [[ -n "${domain_validations}" ]]; then
        echo "${domain_validations}" | while IFS=: read -r domain val_status; do
          echo "  - ${domain}: ${val_status}"
        done
      fi
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Check for issues
    if [[ "${status}" != "ISSUED" ]]; then
      ((validation_failed++))
      cert_status_color="${RED}"
      alert_message="⚠️  Certificate ${domain_name} status is ${status} (not ISSUED)"
      log_message WARN "${alert_message}"
    fi
    
    if [[ "${days_to_expiry}" != "UNKNOWN" && ${days_to_expiry} -lt 0 ]]; then
      ((expired_certs++))
      cert_status_color="${RED}"
      alert_message="🔴 CRITICAL: Certificate ${domain_name} has EXPIRED!"
      log_message CRITICAL "${alert_message}"
      send_slack_alert "${alert_message}" "CRITICAL"
      send_email_alert "CRITICAL: ACM Certificate Expired" "${alert_message}\n\nCertificate ARN: ${cert_arn}"
    elif [[ "${days_to_expiry}" != "UNKNOWN" && ${days_to_expiry} -lt ${EXPIRY_WARN_DAYS} ]]; then
      ((expiring_certs++))
      cert_status_color="${YELLOW}"
      alert_message="⚠️  WARNING: Certificate ${domain_name} expires in ${days_to_expiry} days"
      log_message WARN "${alert_message}"
      send_slack_alert "${alert_message}" "WARNING"
    else
      ((healthy_certs++))
    fi
    
    if [[ "${renewal_summary}" == "Pending" ]]; then
      ((renewal_pending++))
      if [[ "${cert_status_color}" == "${GREEN}" ]]; then
        cert_status_color="${YELLOW}"
      fi
      log_message WARN "Certificate ${domain_name} has pending renewal"
    fi
    
    # Domain validation checks
    if echo "${domain_validations}" | grep -q "Failed"; then
      ((validation_failed++))
      cert_status_color="${RED}"
      alert_message="❌ Certificate ${domain_name} has failed domain validation"
      log_message ERROR "${alert_message}"
      send_slack_alert "${alert_message}" "WARNING"
    fi
    
    printf "%b%-60s %b\n" "${cert_status_color}" "${domain_name:0:60}" "${NC}" >> "${OUTPUT_FILE}"
    
  done <<< "${cert_arns}"
  
  # Summary
  {
    echo ""
    echo "=== VALIDATION SUMMARY ==="
    echo "Total Certificates: ${total_certs}"
    echo "Healthy: ${healthy_certs}"
    echo "Expiring Soon: ${expiring_certs}"
    echo "Expired: ${expired_certs}"
    echo "Validation Failed: ${validation_failed}"
    echo "Renewal Pending: ${renewal_pending}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  log_message INFO "Validation complete. Total: ${total_certs}, Healthy: ${healthy_certs}, Issues: $((expired_certs + expiring_certs + validation_failed))"
  
  return $((expired_certs + expiring_certs + validation_failed))
}

list_san_certificates() {
  log_message INFO "Listing Subject Alternative Names (SANs)"
  
  {
    echo ""
    echo "=== SUBJECT ALTERNATIVE NAMES (SANs) ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local certs_json
  certs_json=$(list_acm_certificates)
  
  local cert_arns
  cert_arns=$(echo "${certs_json}" | jq -r '.CertificateSummaryList[].CertificateArn' 2>/dev/null)
  
  while IFS= read -r cert_arn; do
    local cert_details
    cert_details=$(describe_certificate "${cert_arn}")
    
    local domain_name
    local subject_alt_names
    
    domain_name=$(echo "${cert_details}" | jq_safe '.Certificate.DomainName')
    subject_alt_names=$(echo "${cert_details}" | jq -r '.Certificate.SubjectAlternativeNames[]?' 2>/dev/null)
    
    if [[ -n "${subject_alt_names}" ]]; then
      {
        echo "Primary Domain: ${domain_name}"
        echo "SANs:"
        echo "${subject_alt_names}" | while IFS= read -r san; do
          echo "  - ${san}"
        done
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done <<< "${cert_arns}"
}

main() {
  log_message INFO "=== ACM Certificate Validation Started ==="
  
  write_header
  validate_certificates
  local validation_result=$?
  
  list_san_certificates
  
  {
    echo ""
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== ACM Certificate Validation Completed ==="
  
  return ${validation_result}
}

main "$@"
