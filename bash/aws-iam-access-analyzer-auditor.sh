#!/bin/bash

################################################################################
# AWS IAM Access Analyzer Auditor
# Audits Access Analyzer findings for public and cross-account access
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/iam-access-analyzer-audit-$(date +%s).txt"
LOG_FILE="/var/log/iam-access-analyzer-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-30}"

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
list_analyzers() {
  aws accessanalyzer list-analyzers --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_findings() {
  local analyzer_arn="$1"
  local filter_json="$2"
  aws accessanalyzer list-findings --analyzer-arn "${analyzer_arn}" --finding-criteria "${filter_json}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_finding() {
  local analyzer_arn="$1"
  local id="$2"
  aws accessanalyzer get-finding --analyzer-arn "${analyzer_arn}" --id "${id}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS IAM Access Analyzer Audit"
    echo "=============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback Days: ${LOOKBACK_DAYS}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_analyzers() {
  log_message INFO "Listing Access Analyzer analyzers"
  {
    echo "=== ACCESS ANALYZERS ==="
  } >> "${OUTPUT_FILE}"

  local analyzers_json
  analyzers_json=$(list_analyzers)

  local total_analyzers=0 total_findings=0 public_findings=0 cross_account_findings=0 potential_data_exposure=0 inactive_analyzers=0

  echo "${analyzers_json}" | jq -c '.analyzers[]? // .analyzers[]?' 2>/dev/null | while read -r analyzer; do
    ((total_analyzers++))
    local arn name status created
    arn=$(echo "${analyzer}" | jq_safe '.arn')
    name=$(echo "${analyzer}" | jq_safe '.name')
    status=$(echo "${analyzer}" | jq_safe '.status')
    created=$(echo "${analyzer}" | jq_safe '.createdAt')

    {
      echo "Analyzer: ${name}"
      echo "  ARN: ${arn}"
      echo "  Status: ${status}"
      echo "  Created: ${created}"
    } >> "${OUTPUT_FILE}"

    if [[ "${status}" != "ACTIVE" ]]; then
      ((inactive_analyzers++))
      echo "  WARNING: Analyzer status is ${status}" >> "${OUTPUT_FILE}"
    fi

    # Build filter: ACTIVE findings in lookback window
    local start_epoch
    start_epoch=$(date -d "${LOOKBACK_DAYS} days ago" +%s)000
    local criteria
    criteria=$(cat <<EOF
{
  "Criterion": {
    "status": { "Eq": [ "ACTIVE" ] },
    "createdAt": { "Gte": ${start_epoch} }
  }
}
EOF
)

    local findings_list
    findings_list=$(list_findings "${arn}" "${criteria}")

    local finding_ids=()
    while IFS= read -r fid; do
      [[ -z "${fid}" || "${fid}" == "null" ]] && continue
      finding_ids+=("${fid}")
    done < <(echo "${findings_list}" | jq -r '.findings[]?.id' 2>/dev/null)

    if (( ${#finding_ids[@]} == 0 )); then
      echo "  No recent findings" >> "${OUTPUT_FILE}"
      echo "" >> "${OUTPUT_FILE}"
      continue
    fi

    for id in "${finding_ids[@]}"; do
      ((total_findings++))
      local finding
      finding=$(get_finding "${arn}" "${id}")

      local resourceType resource created principal isPublic
      resourceType=$(echo "${finding}" | jq_safe '.resourceType')
      resource=$(echo "${finding}" | jq_safe '.resource')
      created=$(echo "${finding}" | jq_safe '.createdAt')
      principal=$(echo "${finding}" | jq -c '.principal' 2>/dev/null || echo "{}")
      isPublic=$(echo "${finding}" | jq_safe '.isPublic')

      {
        echo "Finding ID: ${id}"
        echo "  Resource Type: ${resourceType}"
        echo "  Resource: ${resource}"
        echo "  Created: ${created}"
        echo "  Principal: ${principal}"
      } >> "${OUTPUT_FILE}"

      if [[ "${isPublic}" == "true" ]]; then
        ((public_findings++))
        echo "  WARNING: Resource is publicly accessible" >> "${OUTPUT_FILE}"
      fi

      # Check for cross-account principals
      if echo "${principal}" | jq -e '.[]? | select(.principalType == "AWS" and (.principal=="*") | not) ' >/dev/null 2>&1; then
        # attempt to detect account principals (ARNs not belonging to this account)
        if echo "${principal}" | jq -e '.[]? | select(.principalType=="AWS" and (.principal | test("arn:aws:iam::[0-9]{12}:")))' >/dev/null 2>&1; then
          ((cross_account_findings++))
          echo "  WARNING: Cross-account principal detected" >> "${OUTPUT_FILE}"
        fi
      fi

      # Detect potentially sensitive resource types
      case "${resourceType}" in
        AWS::S3::Bucket|S3Bucket)
          ((potential_data_exposure++))
          echo "  INFO: S3 bucket access finding (possible data exposure)" >> "${OUTPUT_FILE}"
          ;;
        AWS::KMS::Key|KMSKey)
          echo "  INFO: KMS key access finding" >> "${OUTPUT_FILE}"
          ;;
        AWS::IAM::Role|IAMRole)
          echo "  INFO: IAM role trust/policy finding" >> "${OUTPUT_FILE}"
          ;;
      esac

      echo "" >> "${OUTPUT_FILE}"
    done

  done

  {
    echo "Access Analyzer Summary:"
    echo "  Total Analyzers: ${total_analyzers}"
    echo "  Total Findings (lookback ${LOOKBACK_DAYS}d): ${total_findings}"
    echo "  Public Findings: ${public_findings}"
    echo "  Cross-Account Findings: ${cross_account_findings}"
    echo "  Potential Data Exposure (S3/KMS): ${potential_data_exposure}"
    echo "  Inactive Analyzers: ${inactive_analyzers}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local public="$2"; local cross="$3"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  (( public > 0 )) && color="danger"
  (( cross > 0 && public == 0 )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Access Analyzer Audit Report",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Total Findings", "value": "${total}", "short": true},
        {"title": "Public Findings", "value": "${public}", "short": true},
        {"title": "Cross-Account Findings", "value": "${cross}", "short": true},
        {"title": "Lookback", "value": "${LOOKBACK_DAYS}d", "short": true},
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
  log_message INFO "Starting Access Analyzer audit"
  write_header
  audit_analyzers
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total public cross
  total=$(grep "Total Findings" "${OUTPUT_FILE}" | awk -F: '{print $2}' | tr -d ' ' | head -1)
  public=$(grep "Public Findings:" "${OUTPUT_FILE}" | awk -F: '{print $2}' | tr -d ' ' | head -1)
  cross=$(grep "Cross-Account Findings:" "${OUTPUT_FILE}" | awk -F: '{print $2}' | tr -d ' ' | head -1)
  [[ -z "${total}" ]] && total=0
  [[ -z "${public}" ]] && public=0
  [[ -z "${cross}" ]] && cross=0
  send_slack_alert "${total}" "${public}" "${cross}"
  cat "${OUTPUT_FILE}"
}

main "$@"
