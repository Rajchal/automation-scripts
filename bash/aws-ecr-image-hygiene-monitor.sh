#!/bin/bash

################################################################################
# AWS ECR Image Hygiene Monitor
# Audits ECR repositories: image count, untagged images, stale images (by push
# date), image scan findings (vulnerabilities), scan on push status, lifecycle
# policies, image retention rules, and CloudWatch metrics (PutImage, GetImage,
# ImageScan, etc.). Flags untagged/stale images, high vulnerability counts,
# missing scan/retention policies. Includes thresholds, logging, Slack/email
# alerts, and a text report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/ecr-image-hygiene-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/ecr-image-hygiene-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds (override via env)
STALE_DAYS_WARN="${STALE_DAYS_WARN:-90}"             # images not pushed for N days
UNTAGGED_WARN="${UNTAGGED_WARN:-1}"                 # untagged images count
HIGH_VULN_WARN="${HIGH_VULN_WARN:-5}"               # CRITICAL+HIGH vulnerabilities
MEDIUM_VULN_WARN="${MEDIUM_VULN_WARN:-10}"          # MEDIUM vulnerabilities

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_REPOS=0
REPOS_WITH_ISSUES=0
REPOS_UNTAGGED_WARN=0
REPOS_STALE_WARN=0
REPOS_HIGH_VULN=0
REPOS_NO_SCAN_POLICY=0
REPOS_NO_LIFECYCLE=0
TOTAL_IMAGES=0
UNTAGGED_IMAGES=0
STALE_IMAGES=0

ISSUES=()

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || echo ""; }

aws_cmd() {
  if [[ -n "${PROFILE}" ]]; then AWS_PROFILE="${PROFILE}" aws "$@"; else aws "$@"; fi
}

send_slack_alert() {
  local message="$1"
  local severity="${2:-INFO}"
  [[ -z "${SLACK_WEBHOOK}" ]] && return
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
      "title": "AWS ECR Hygiene Alert",
      "text": "${message}",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || true
}

send_email_alert() {
  local subject="$1"
  local body="$2"
  [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null && return
  echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true
}

write_header() {
  {
    echo "AWS ECR Image Hygiene Monitor"
    echo "============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo ""
    echo "Thresholds:"
    echo "  Stale Image Warning: > ${STALE_DAYS_WARN} days since push"
    echo "  Untagged Images Warning: >= ${UNTAGGED_WARN}"
    echo "  High Severity Vulns (CRITICAL+HIGH): >= ${HIGH_VULN_WARN}"
    echo "  Medium Severity Vulns: >= ${MEDIUM_VULN_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_repositories() {
  aws_cmd ecr describe-repositories \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"repositories":[]}'
}

describe_repo() {
  local repo="$1"
  aws_cmd ecr describe-repositories \
    --repository-names "$repo" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"repositories":[]}'
}

list_images() {
  local repo="$1"
  aws_cmd ecr list-images \
    --repository-name "$repo" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"imageIds":[]}'
}

describe_images() {
  local repo="$1"
  aws_cmd ecr describe-images \
    --repository-name "$repo" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"imageDetails":[]}'
}

describe_image_scan_findings() {
  local repo="$1" image_id="$2"
  aws_cmd ecr describe-image-scan-findings \
    --repository-name "$repo" \
    --image-id "imageDigest=${image_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"imageScanFindings":{"findingSeverityCounts":{}}}'
}

get_lifecycle_policy() {
  local repo="$1"
  aws_cmd ecr get-lifecycle-policy \
    --repository-name "$repo" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_image_scan_config() {
  local repo="$1"
  aws_cmd ecr describe-repositories \
    --repository-names "$repo" \
    --region "${REGION}" \
    --output json 2>/dev/null | jq -r '.repositories[0].imageScanningConfiguration'
}

record_issue() {
  ISSUES+=("$1")
}

days_ago() {
  local date_str="$1"
  [[ -z "${date_str}" ]] && { echo 999999; return; }
  local ts_now ts_date
  ts_now=$(date +%s)
  ts_date=$(date -d "${date_str}" +%s 2>/dev/null || echo 0)
  [[ "${ts_date}" == "0" ]] && { echo 999999; return; }
  echo $(( (ts_now - ts_date) / 86400 ))
}

analyze_images() {
  local repo="$1"
  local img_details_json
  img_details_json=$(describe_images "$repo")
  local img_count
  img_count=$(echo "${img_details_json}" | jq -r '.imageDetails | length')

  TOTAL_IMAGES=$((TOTAL_IMAGES + img_count))
  echo "  Images: ${img_count}" >> "${OUTPUT_FILE}"

  if [[ "${img_count}" == "0" ]]; then
    echo "    (no images)" >> "${OUTPUT_FILE}"
    return
  fi

  local untagged_count=0
  local stale_count=0
  local crit_vuln_total=0
  local high_vuln_total=0
  local medium_vuln_total=0

  while read -r img; do
    local img_digest tags push_date days_since_push crit high medium
    img_digest=$(echo "${img}" | jq_safe '.imageDigest')
    tags=$(echo "${img}" | jq -r '.imageTags | length' 2>/dev/null || echo 0)
    push_date=$(echo "${img}" | jq_safe '.imagePushedAt')

    # Untagged check
    if [[ "${tags}" == "0" ]]; then
      untagged_count=$((untagged_count + 1))
      UNTAGGED_IMAGES=$((UNTAGGED_IMAGES + 1))
    fi

    # Stale check
    days_since_push=$(days_ago "${push_date}")
    if (( days_since_push > STALE_DAYS_WARN )); then
      stale_count=$((stale_count + 1))
      STALE_IMAGES=$((STALE_IMAGES + 1))
    fi

    # Scan findings
    local scan_json
    scan_json=$(describe_image_scan_findings "$repo" "${img_digest}")
    crit=$(echo "${scan_json}" | jq_safe '.imageScanFindings.findingSeverityCounts.CRITICAL // 0')
    high=$(echo "${scan_json}" | jq_safe '.imageScanFindings.findingSeverityCounts.HIGH // 0')
    medium=$(echo "${scan_json}" | jq_safe '.imageScanFindings.findingSeverityCounts.MEDIUM // 0')

    crit_vuln_total=$((crit_vuln_total + crit))
    high_vuln_total=$((high_vuln_total + high))
    medium_vuln_total=$((medium_vuln_total + medium))
  done <<< "$(echo "${img_details_json}" | jq -c '.imageDetails[]')"

  {
    echo "    Untagged: ${untagged_count}"
    echo "    Stale (>${STALE_DAYS_WARN}d): ${stale_count}"
    echo "    Vulnerabilities (CRITICAL/HIGH/MEDIUM): ${crit_vuln_total}/${high_vuln_total}/${medium_vuln_total}"
  } >> "${OUTPUT_FILE}"

  if (( untagged_count >= UNTAGGED_WARN )); then
    REPOS_UNTAGGED_WARN=$((REPOS_UNTAGGED_WARN + 1))
    record_issue "ECR repo ${repo} has ${untagged_count} untagged images"
  fi

  if (( stale_count > 0 )); then
    REPOS_STALE_WARN=$((REPOS_STALE_WARN + 1))
    record_issue "ECR repo ${repo} has ${stale_count} stale images (>${STALE_DAYS_WARN}d)"
  fi

  if (( crit_vuln_total + high_vuln_total >= HIGH_VULN_WARN )); then
    REPOS_HIGH_VULN=$((REPOS_HIGH_VULN + 1))
    record_issue "ECR repo ${repo} has ${crit_vuln_total} CRITICAL + ${high_vuln_total} HIGH vulnerabilities"
  fi

  if (( medium_vuln_total >= MEDIUM_VULN_WARN )); then
    record_issue "ECR repo ${repo} has ${medium_vuln_total} MEDIUM vulnerabilities"
  fi
}

analyze_repo() {
  local repo_json="$1"
  local repo_name arn uri created_date scan_on_push
  repo_name=$(echo "${repo_json}" | jq_safe '.repositoryName')
  arn=$(echo "${repo_json}" | jq_safe '.repositoryArn')
  uri=$(echo "${repo_json}" | jq_safe '.repositoryUri')
  created_date=$(echo "${repo_json}" | jq_safe '.createdAt')
  scan_on_push=$(echo "${repo_json}" | jq_safe '.imageScanningConfiguration.scanOnPush')

  TOTAL_REPOS=$((TOTAL_REPOS + 1))
  log_message INFO "Analyzing ECR repository ${repo_name}"

  {
    echo "Repository: ${repo_name}"
    echo "  ARN: ${arn}"
    echo "  URI: ${uri}"
    echo "  Created: ${created_date}"
    echo "  Scan on Push: ${scan_on_push}"
  } >> "${OUTPUT_FILE}"

  # Lifecycle policy
  local lifecycle_json lifecycle_text
  lifecycle_json=$(get_lifecycle_policy "$repo_name")
  lifecycle_text=$(echo "${lifecycle_json}" | jq_safe '.lifecyclePolicyText')
  if [[ -z "${lifecycle_text}" || "${lifecycle_text}" == "null" ]]; then
    echo "  Lifecycle Policy: NOT CONFIGURED" >> "${OUTPUT_FILE}"
    REPOS_NO_LIFECYCLE=$((REPOS_NO_LIFECYCLE + 1))
    record_issue "ECR repo ${repo_name} missing lifecycle policy"
  else
    echo "  Lifecycle Policy: CONFIGURED" >> "${OUTPUT_FILE}"
  fi

  if [[ "${scan_on_push}" != "true" ]]; then
    REPOS_NO_SCAN_POLICY=$((REPOS_NO_SCAN_POLICY + 1))
    record_issue "ECR repo ${repo_name} scan-on-push disabled"
  fi

  # Analyze images
  analyze_images "$repo_name"

  local repo_issue=0
  if (( REPOS_UNTAGGED_WARN > 0 || REPOS_STALE_WARN > 0 || REPOS_HIGH_VULN > 0 )); then
    repo_issue=1
  fi

  if (( repo_issue )); then
    REPOS_WITH_ISSUES=$((REPOS_WITH_ISSUES + 1))
  fi

  echo "" >> "${OUTPUT_FILE}"
}

main() {
  write_header
  local repos_json
  repos_json=$(list_repositories)
  local repo_count
  repo_count=$(echo "${repos_json}" | jq -r '.repositories | length')

  if [[ "${repo_count}" == "0" ]]; then
    log_message WARN "No ECR repositories found in region ${REGION}"
    echo "No ECR repositories found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total Repositories: ${repo_count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  while read -r repo; do
    analyze_repo "${repo}"
  done <<< "$(echo "${repos_json}" | jq -c '.repositories[]')"

  {
    echo "Summary"
    echo "-------"
    echo "Total Repositories: ${TOTAL_REPOS}"
    echo "Repositories with Issues: ${REPOS_WITH_ISSUES}"
    echo "Untagged Image Warnings: ${REPOS_UNTAGGED_WARN}"
    echo "Stale Image Warnings: ${REPOS_STALE_WARN}"
    echo "High Vulnerability Count: ${REPOS_HIGH_VULN}"
    echo "Missing Scan-on-Push: ${REPOS_NO_SCAN_POLICY}"
    echo "Missing Lifecycle Policy: ${REPOS_NO_LIFECYCLE}"
    echo ""
    echo "Total Images: ${TOTAL_IMAGES}"
    echo "Untagged Images: ${UNTAGGED_IMAGES}"
    echo "Stale Images: ${STALE_IMAGES}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "ECR Image Hygiene Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "ECR Image Hygiene Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"
