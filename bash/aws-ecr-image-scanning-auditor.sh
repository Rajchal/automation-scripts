#!/bin/bash

################################################################################
# AWS ECR Image Scanning Auditor
# Audits ECR repositories for unscanned images and vulnerability findings
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/ecr-scanning-audit-$(date +%s).txt"
LOG_FILE="/var/log/ecr-scanning-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
CRITICAL_SEVERITY_THRESHOLD="${CRITICAL_SEVERITY_THRESHOLD:-1}"    # critical findings
HIGH_SEVERITY_THRESHOLD="${HIGH_SEVERITY_THRESHOLD:-5}"            # high findings
IMAGE_AGE_WARN_DAYS="${IMAGE_AGE_WARN_DAYS:-90}"                   # old untagged images

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

# Helpers
jq_safe() { jq -r "$1" 2>/dev/null || true; }

# API wrappers
list_repositories() {
  aws ecr describe-repositories \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_images() {
  local repo="$1"
  aws ecr list-images \
    --repository-name "${repo}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_images() {
  local repo="$1"
  aws ecr describe-images \
    --repository-name "${repo}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_image_scan_findings() {
  local repo="$1"; local image_digest="$2"
  aws ecr describe-image-scan-findings \
    --repository-name "${repo}" \
    --image-id imageDigest="${image_digest}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_lifecycle_policy() {
  local repo="$1"
  aws ecr get-lifecycle-policy \
    --repository-name "${repo}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS ECR Image Scanning Audit Report"
    echo "===================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Critical Threshold: ${CRITICAL_SEVERITY_THRESHOLD}"
    echo "High Threshold: ${HIGH_SEVERITY_THRESHOLD}"
    echo "Image Age Warn: ${IMAGE_AGE_WARN_DAYS} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_repositories() {
  log_message INFO "Auditing ECR repositories"
  {
    echo "=== REPOSITORIES ==="
  } >> "${OUTPUT_FILE}"

  local total_repos=0 scan_on_push_enabled=0 scan_on_push_disabled=0 immutable=0 mutable=0

  local repos_json
  repos_json=$(list_repositories)
  echo "${repos_json}" | jq -c '.repositories[]?' 2>/dev/null | while read -r repo; do
    ((total_repos++))
    local repo_name repo_uri created scan_config immutability encryption
    repo_name=$(echo "${repo}" | jq_safe '.repositoryName')
    repo_uri=$(echo "${repo}" | jq_safe '.repositoryUri')
    created=$(echo "${repo}" | jq_safe '.createdAt')
    scan_config=$(echo "${repo}" | jq_safe '.imageScanningConfiguration.scanOnPush')
    immutability=$(echo "${repo}" | jq_safe '.imageTagMutability')
    encryption=$(echo "${repo}" | jq_safe '.encryptionConfiguration.encryptionType')

    {
      echo "Repository: ${repo_name}"
      echo "  URI: ${repo_uri}"
      echo "  Created: ${created}"
      echo "  Scan on Push: ${scan_config}"
      echo "  Tag Mutability: ${immutability}"
      echo "  Encryption: ${encryption}"
    } >> "${OUTPUT_FILE}"

    if [[ "${scan_config}" == "true" ]]; then
      ((scan_on_push_enabled++))
    else
      ((scan_on_push_disabled++))
      echo "  WARNING: Scan on push is disabled" >> "${OUTPUT_FILE}"
    fi

    if [[ "${immutability}" == "IMMUTABLE" ]]; then
      ((immutable++))
    else
      ((mutable++))
    fi

    # Check lifecycle policy
    local lifecycle
    lifecycle=$(get_lifecycle_policy "${repo_name}")
    if [[ -n "${lifecycle}" && "${lifecycle}" != "{}" ]]; then
      echo "  Lifecycle Policy: present" >> "${OUTPUT_FILE}"
    else
      echo "  Lifecycle Policy: none" >> "${OUTPUT_FILE}"
      echo "  WARNING: No lifecycle policy configured" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Repository Summary:"
    echo "  Total: ${total_repos}"
    echo "  Scan on Push Enabled: ${scan_on_push_enabled}"
    echo "  Scan on Push Disabled: ${scan_on_push_disabled}"
    echo "  Immutable Tags: ${immutable}"
    echo "  Mutable Tags: ${mutable}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_image_vulnerabilities() {
  log_message INFO "Analyzing image scan findings"
  {
    echo "=== IMAGE VULNERABILITY FINDINGS ==="
  } >> "${OUTPUT_FILE}"

  local total_images=0 scanned_images=0 unscanned_images=0 critical_vulns=0 high_vulns=0

  local repos_json
  repos_json=$(list_repositories)
  echo "${repos_json}" | jq -c '.repositories[]?' 2>/dev/null | while read -r repo; do
    local repo_name
    repo_name=$(echo "${repo}" | jq_safe '.repositoryName')

    local images_json
    images_json=$(describe_images "${repo_name}")

    echo "${images_json}" | jq -c '.imageDetails[]?' 2>/dev/null | head -20 | while read -r image; do
      ((total_images++))
      local image_digest image_tags pushed_at scan_status
      image_digest=$(echo "${image}" | jq_safe '.imageDigest')
      image_tags=$(echo "${image}" | jq -r '.imageTags[]?' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "untagged")
      pushed_at=$(echo "${image}" | jq_safe '.imagePushedAt')
      scan_status=$(echo "${image}" | jq_safe '.imageScanStatus.status')

      if [[ "${scan_status}" == "COMPLETE" ]]; then
        ((scanned_images++))
        
        # Get scan findings
        local findings
        findings=$(describe_image_scan_findings "${repo_name}" "${image_digest}")
        
        local critical high medium low
        critical=$(echo "${findings}" | jq '.imageScanFindings.findingSeverityCounts.CRITICAL // 0' 2>/dev/null || echo 0)
        high=$(echo "${findings}" | jq '.imageScanFindings.findingSeverityCounts.HIGH // 0' 2>/dev/null || echo 0)
        medium=$(echo "${findings}" | jq '.imageScanFindings.findingSeverityCounts.MEDIUM // 0' 2>/dev/null || echo 0)
        low=$(echo "${findings}" | jq '.imageScanFindings.findingSeverityCounts.LOW // 0' 2>/dev/null || echo 0)

        if (( critical > 0 || high > 0 )); then
          {
            echo "Repository: ${repo_name}"
            echo "  Tags: ${image_tags}"
            echo "  Digest: ${image_digest}"
            echo "  Pushed: ${pushed_at}"
            echo "  Scan Status: ${scan_status}"
            echo "  Vulnerabilities:"
            echo "    CRITICAL: ${critical}"
            echo "    HIGH: ${high}"
            echo "    MEDIUM: ${medium}"
            echo "    LOW: ${low}"
          } >> "${OUTPUT_FILE}"

          if (( critical >= CRITICAL_SEVERITY_THRESHOLD )); then
            ((critical_vulns++))
            echo "  WARNING: ${critical} CRITICAL vulnerabilities found (>= ${CRITICAL_SEVERITY_THRESHOLD})" >> "${OUTPUT_FILE}"
          fi
          if (( high >= HIGH_SEVERITY_THRESHOLD )); then
            ((high_vulns++))
            echo "  WARNING: ${high} HIGH vulnerabilities found (>= ${HIGH_SEVERITY_THRESHOLD})" >> "${OUTPUT_FILE}"
          fi

          echo "" >> "${OUTPUT_FILE}"
        fi
      elif [[ "${scan_status}" == "IN_PROGRESS" ]]; then
        ((scanned_images++))
      else
        ((unscanned_images++))
      fi
    done
  done

  {
    echo "Vulnerability Summary (sample of 20 images per repo):"
    echo "  Total Images Sampled: ${total_images}"
    echo "  Scanned: ${scanned_images}"
    echo "  Unscanned: ${unscanned_images}"
    echo "  Images with CRITICAL: ${critical_vulns}"
    echo "  Images with HIGH: ${high_vulns}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_unscanned_images() {
  log_message INFO "Identifying unscanned images"
  {
    echo "=== UNSCANNED IMAGES ==="
  } >> "${OUTPUT_FILE}"

  local unscanned_count=0

  local repos_json
  repos_json=$(list_repositories)
  echo "${repos_json}" | jq -c '.repositories[]?' 2>/dev/null | while read -r repo; do
    local repo_name
    repo_name=$(echo "${repo}" | jq_safe '.repositoryName')

    local images_json
    images_json=$(describe_images "${repo_name}")

    echo "${images_json}" | jq -c '.imageDetails[]?' 2>/dev/null | while read -r image; do
      local image_digest image_tags pushed_at scan_status
      image_digest=$(echo "${image}" | jq_safe '.imageDigest')
      image_tags=$(echo "${image}" | jq -r '.imageTags[]?' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "untagged")
      pushed_at=$(echo "${image}" | jq_safe '.imagePushedAt')
      scan_status=$(echo "${image}" | jq_safe '.imageScanStatus.status')

      if [[ "${scan_status}" != "COMPLETE" && "${scan_status}" != "IN_PROGRESS" ]]; then
        ((unscanned_count++))
        {
          echo "Repository: ${repo_name}"
          echo "  Tags: ${image_tags}"
          echo "  Pushed: ${pushed_at}"
          echo "  Scan Status: ${scan_status}"
          echo "  WARNING: Image has not been scanned"
          echo ""
        } >> "${OUTPUT_FILE}"
      fi
    done
  done

  {
    echo "Unscanned Images: ${unscanned_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_old_untagged_images() {
  log_message INFO "Checking for old untagged images"
  {
    echo "=== OLD UNTAGGED IMAGES ==="
  } >> "${OUTPUT_FILE}"

  local old_untagged=0

  local repos_json
  repos_json=$(list_repositories)
  echo "${repos_json}" | jq -c '.repositories[]?' 2>/dev/null | while read -r repo; do
    local repo_name
    repo_name=$(echo "${repo}" | jq_safe '.repositoryName')

    local images_json
    images_json=$(describe_images "${repo_name}")

    echo "${images_json}" | jq -c '.imageDetails[]?' 2>/dev/null | while read -r image; do
      local image_digest image_tags pushed_at
      image_digest=$(echo "${image}" | jq_safe '.imageDigest')
      image_tags=$(echo "${image}" | jq -r '.imageTags[]?' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
      pushed_at=$(echo "${image}" | jq_safe '.imagePushedAt')

      # Check if untagged
      if [[ -z "${image_tags}" ]]; then
        # Calculate age
        local pushed_epoch now_epoch age_days
        pushed_epoch=$(date -d "${pushed_at}" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        age_days=$(( (now_epoch - pushed_epoch) / 86400 ))

        if (( age_days >= IMAGE_AGE_WARN_DAYS )); then
          ((old_untagged++))
          {
            echo "Repository: ${repo_name}"
            echo "  Digest: ${image_digest}"
            echo "  Pushed: ${pushed_at}"
            echo "  Age: ${age_days} days"
            echo "  WARNING: Untagged image older than ${IMAGE_AGE_WARN_DAYS} days"
            echo ""
          } >> "${OUTPUT_FILE}"
        fi
      fi
    done
  done

  {
    echo "Old Untagged Images: ${old_untagged}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_public_repositories() {
  log_message INFO "Checking for public repositories"
  {
    echo "=== PUBLIC REPOSITORY AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local public_count=0

  local repos_json
  repos_json=$(list_repositories)
  echo "${repos_json}" | jq -c '.repositories[]?' 2>/dev/null | while read -r repo; do
    local repo_name
    repo_name=$(echo "${repo}" | jq_safe '.repositoryName')

    # Check repository policy
    local policy
    policy=$(aws ecr get-repository-policy \
      --repository-name "${repo_name}" \
      --region "${REGION}" \
      --output json 2>/dev/null || echo '{}')

    if [[ -n "${policy}" && "${policy}" != "{}" ]]; then
      local policy_text
      policy_text=$(echo "${policy}" | jq_safe '.policyText')
      
      # Check for public access
      local has_public
      has_public=$(echo "${policy_text}" | jq '.Statement[]? | select(.Effect=="Allow" and (.Principal=="*" or .Principal.AWS=="*"))' 2>/dev/null | wc -l)

      if (( has_public > 0 )); then
        ((public_count++))
        {
          echo "Repository: ${repo_name}"
          echo "  WARNING: Repository policy allows public access"
          echo ""
        } >> "${OUTPUT_FILE}"
      fi
    fi
  done

  {
    echo "Public Repository Summary:"
    echo "  Public Repositories: ${public_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total_repos="$1"; local unscanned="$2"; local critical="$3"; local high="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS ECR Image Scanning Audit Report",
  "attachments": [
    {
      "color": "danger",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Repositories", "value": "${total_repos}", "short": true},
        {"title": "Unscanned Images", "value": "${unscanned}", "short": true},
        {"title": "CRITICAL Vulns", "value": "${critical}", "short": true},
        {"title": "HIGH Vulns", "value": "${high}", "short": true},
        {"title": "Critical Threshold", "value": "${CRITICAL_SEVERITY_THRESHOLD}", "short": true},
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
  log_message INFO "Starting AWS ECR image scanning audit"
  write_header
  report_repositories
  report_image_vulnerabilities
  report_unscanned_images
  report_old_untagged_images
  report_public_repositories
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total_repos unscanned critical high
  total_repos=$(grep "Total:" "${OUTPUT_FILE}" | grep "Repository Summary" -A1 | tail -1 | awk '{print $NF}')
  unscanned=$(grep "Unscanned Images:" "${OUTPUT_FILE}" | tail -1 | awk '{print $NF}')
  critical=$(grep "Images with CRITICAL:" "${OUTPUT_FILE}" | awk '{print $NF}')
  high=$(grep "Images with HIGH:" "${OUTPUT_FILE}" | awk '{print $NF}')
  send_slack_alert "${total_repos}" "${unscanned}" "${critical}" "${high}"
  cat "${OUTPUT_FILE}"
}

main "$@"
