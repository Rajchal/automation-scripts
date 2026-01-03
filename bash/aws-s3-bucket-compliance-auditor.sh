#!/bin/bash

################################################################################
# AWS S3 Bucket Compliance Auditor
# Audits S3 buckets for versioning, encryption, public access, and security settings
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/s3-compliance-audit-$(date +%s).txt"
LOG_FILE="/var/log/s3-compliance-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

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
list_buckets() {
  aws s3api list-buckets \
    --output json 2>/dev/null || echo '{}'
}

get_bucket_location() {
  local bucket="$1"
  aws s3api get-bucket-location \
    --bucket "${bucket}" \
    --output json 2>/dev/null | jq -r '.LocationConstraint // "us-east-1"' || echo "unknown"
}

get_bucket_versioning() {
  local bucket="$1"
  aws s3api get-bucket-versioning \
    --bucket "${bucket}" \
    --output json 2>/dev/null || echo '{}'
}

get_bucket_encryption() {
  local bucket="$1"
  aws s3api get-bucket-encryption \
    --bucket "${bucket}" \
    --output json 2>/dev/null || echo '{}'
}

get_public_access_block() {
  local bucket="$1"
  aws s3api get-public-access-block \
    --bucket "${bucket}" \
    --output json 2>/dev/null || echo '{}'
}

get_bucket_policy() {
  local bucket="$1"
  aws s3api get-bucket-policy \
    --bucket "${bucket}" \
    --output json 2>/dev/null || echo '{}'
}

get_bucket_acl() {
  local bucket="$1"
  aws s3api get-bucket-acl \
    --bucket "${bucket}" \
    --output json 2>/dev/null || echo '{}'
}

get_bucket_logging() {
  local bucket="$1"
  aws s3api get-bucket-logging \
    --bucket "${bucket}" \
    --output json 2>/dev/null || echo '{}'
}

get_bucket_lifecycle() {
  local bucket="$1"
  aws s3api get-bucket-lifecycle-configuration \
    --bucket "${bucket}" \
    --output json 2>/dev/null || echo '{}'
}

get_bucket_replication() {
  local bucket="$1"
  aws s3api get-bucket-replication \
    --bucket "${bucket}" \
    --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS S3 Bucket Compliance Audit Report"
    echo "======================================"
    echo "Generated: $(date)"
    echo "Region Filter: ${REGION}"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_buckets() {
  log_message INFO "Auditing S3 buckets for compliance"
  {
    echo "=== BUCKET COMPLIANCE AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local total=0 versioning_enabled=0 versioning_disabled=0 encrypted=0 unencrypted=0
  local public_block_enabled=0 public_block_disabled=0 logging_enabled=0 logging_disabled=0
  local mfa_delete_enabled=0

  local buckets_json
  buckets_json=$(list_buckets)
  echo "${buckets_json}" | jq -c '.Buckets[]?' 2>/dev/null | while read -r bucket; do
    ((total++))
    local bucket_name created
    bucket_name=$(echo "${bucket}" | jq_safe '.Name')
    created=$(echo "${bucket}" | jq_safe '.CreationDate')

    local location
    location=$(get_bucket_location "${bucket_name}")

    {
      echo "Bucket: ${bucket_name}"
      echo "  Created: ${created}"
      echo "  Region: ${location}"
    } >> "${OUTPUT_FILE}"

    # Versioning
    local versioning_json versioning_status mfa_delete
    versioning_json=$(get_bucket_versioning "${bucket_name}")
    versioning_status=$(echo "${versioning_json}" | jq_safe '.Status')
    mfa_delete=$(echo "${versioning_json}" | jq_safe '.MFADelete')

    if [[ "${versioning_status}" == "Enabled" ]]; then
      ((versioning_enabled++))
      echo "  Versioning: ENABLED" >> "${OUTPUT_FILE}"
    else
      ((versioning_disabled++))
      echo "  Versioning: DISABLED" >> "${OUTPUT_FILE}"
      echo "  WARNING: Versioning is not enabled" >> "${OUTPUT_FILE}"
    fi

    if [[ "${mfa_delete}" == "Enabled" ]]; then
      ((mfa_delete_enabled++))
      echo "  MFA Delete: ENABLED" >> "${OUTPUT_FILE}"
    else
      echo "  MFA Delete: DISABLED" >> "${OUTPUT_FILE}"
    fi

    # Encryption
    local encryption_json encryption_algo kms_key
    encryption_json=$(get_bucket_encryption "${bucket_name}")
    encryption_algo=$(echo "${encryption_json}" | jq_safe '.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm')
    kms_key=$(echo "${encryption_json}" | jq_safe '.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID')

    if [[ -n "${encryption_algo}" && "${encryption_algo}" != "null" ]]; then
      ((encrypted++))
      echo "  Encryption: ENABLED (${encryption_algo})" >> "${OUTPUT_FILE}"
      if [[ -n "${kms_key}" && "${kms_key}" != "null" ]]; then
        echo "  KMS Key: ${kms_key}" >> "${OUTPUT_FILE}"
      fi
    else
      ((unencrypted++))
      echo "  Encryption: DISABLED" >> "${OUTPUT_FILE}"
      echo "  WARNING: Default encryption is not enabled" >> "${OUTPUT_FILE}"
    fi

    # Public Access Block
    local pab_json block_public_acls ignore_public_acls block_public_policy restrict_public_buckets
    pab_json=$(get_public_access_block "${bucket_name}")
    block_public_acls=$(echo "${pab_json}" | jq_safe '.PublicAccessBlockConfiguration.BlockPublicAcls')
    ignore_public_acls=$(echo "${pab_json}" | jq_safe '.PublicAccessBlockConfiguration.IgnorePublicAcls')
    block_public_policy=$(echo "${pab_json}" | jq_safe '.PublicAccessBlockConfiguration.BlockPublicPolicy')
    restrict_public_buckets=$(echo "${pab_json}" | jq_safe '.PublicAccessBlockConfiguration.RestrictPublicBuckets')

    if [[ "${block_public_acls}" == "true" && "${ignore_public_acls}" == "true" && \
          "${block_public_policy}" == "true" && "${restrict_public_buckets}" == "true" ]]; then
      ((public_block_enabled++))
      echo "  Public Access Block: ENABLED (all settings)" >> "${OUTPUT_FILE}"
    else
      ((public_block_disabled++))
      echo "  Public Access Block: PARTIAL or DISABLED" >> "${OUTPUT_FILE}"
      echo "    BlockPublicAcls: ${block_public_acls}" >> "${OUTPUT_FILE}"
      echo "    IgnorePublicAcls: ${ignore_public_acls}" >> "${OUTPUT_FILE}"
      echo "    BlockPublicPolicy: ${block_public_policy}" >> "${OUTPUT_FILE}"
      echo "    RestrictPublicBuckets: ${restrict_public_buckets}" >> "${OUTPUT_FILE}"
      echo "  WARNING: Public Access Block not fully enabled" >> "${OUTPUT_FILE}"
    fi

    # Logging
    local logging_json target_bucket
    logging_json=$(get_bucket_logging "${bucket_name}")
    target_bucket=$(echo "${logging_json}" | jq_safe '.LoggingEnabled.TargetBucket')

    if [[ -n "${target_bucket}" && "${target_bucket}" != "null" ]]; then
      ((logging_enabled++))
      echo "  Access Logging: ENABLED (target: ${target_bucket})" >> "${OUTPUT_FILE}"
    else
      ((logging_disabled++))
      echo "  Access Logging: DISABLED" >> "${OUTPUT_FILE}"
      echo "  WARNING: Access logging is not enabled" >> "${OUTPUT_FILE}"
    fi

    # Lifecycle
    local lifecycle_json rule_count
    lifecycle_json=$(get_bucket_lifecycle "${bucket_name}")
    rule_count=$(echo "${lifecycle_json}" | jq '.Rules | length' 2>/dev/null || echo 0)

    if (( rule_count > 0 )); then
      echo "  Lifecycle Rules: ${rule_count}" >> "${OUTPUT_FILE}"
    else
      echo "  Lifecycle Rules: none" >> "${OUTPUT_FILE}"
    fi

    # Replication
    local replication_json replication_rules
    replication_json=$(get_bucket_replication "${bucket_name}")
    replication_rules=$(echo "${replication_json}" | jq '.ReplicationConfiguration.Rules | length' 2>/dev/null || echo 0)

    if (( replication_rules > 0 )); then
      echo "  Replication Rules: ${replication_rules}" >> "${OUTPUT_FILE}"
    else
      echo "  Replication: none" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Bucket Summary:"
    echo "  Total: ${total}"
    echo "  Versioning Enabled: ${versioning_enabled}"
    echo "  Versioning Disabled: ${versioning_disabled}"
    echo "  Encrypted: ${encrypted}"
    echo "  Unencrypted: ${unencrypted}"
    echo "  Public Access Block: ${public_block_enabled}"
    echo "  Public Access Exposed: ${public_block_disabled}"
    echo "  Logging Enabled: ${logging_enabled}"
    echo "  Logging Disabled: ${logging_disabled}"
    echo "  MFA Delete Enabled: ${mfa_delete_enabled}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_public_buckets() {
  log_message INFO "Checking for publicly accessible buckets"
  {
    echo "=== PUBLIC BUCKET AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local public_count=0

  local buckets_json
  buckets_json=$(list_buckets)
  echo "${buckets_json}" | jq -c '.Buckets[]?' 2>/dev/null | while read -r bucket; do
    local bucket_name
    bucket_name=$(echo "${bucket}" | jq_safe '.Name')

    # Check ACL for public grants
    local acl_json
    acl_json=$(get_bucket_acl "${bucket_name}")
    local public_read public_write
    public_read=$(echo "${acl_json}" | jq '.Grants[]? | select(.Grantee.URI=="http://acs.amazonaws.com/groups/global/AllUsers" or .Grantee.URI=="http://acs.amazonaws.com/groups/global/AuthenticatedUsers")' 2>/dev/null | wc -l)

    # Check policy for public access
    local policy_json
    policy_json=$(get_bucket_policy "${bucket_name}")
    local public_policy
    public_policy=$(echo "${policy_json}" | jq '.Policy' 2>/dev/null | jq '.Statement[]? | select(.Effect=="Allow" and (.Principal=="*" or .Principal.AWS=="*"))' 2>/dev/null | wc -l)

    if (( public_read > 0 || public_policy > 0 )); then
      ((public_count++))
      {
        echo "Bucket: ${bucket_name}"
        echo "  Public ACL Grants: ${public_read}"
        echo "  Public Policy Statements: ${public_policy}"
        echo "  WARNING: Bucket has public access via ACL or policy"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo "Public Bucket Summary:"
    echo "  Publicly Accessible: ${public_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_bucket_policies() {
  log_message INFO "Auditing bucket policies for insecure configurations"
  {
    echo "=== BUCKET POLICY AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local insecure_transport=0 overly_permissive=0

  local buckets_json
  buckets_json=$(list_buckets)
  echo "${buckets_json}" | jq -c '.Buckets[]?' 2>/dev/null | while read -r bucket; do
    local bucket_name
    bucket_name=$(echo "${bucket}" | jq_safe '.Name')

    local policy_json
    policy_json=$(get_bucket_policy "${bucket_name}")
    
    if [[ -z "${policy_json}" || "${policy_json}" == "{}" ]]; then
      continue
    fi

    local policy_text
    policy_text=$(echo "${policy_json}" | jq_safe '.Policy')

    # Check for policies allowing unencrypted transport
    local allows_http
    allows_http=$(echo "${policy_text}" | jq '.Statement[]? | select(.Effect=="Allow" and (.Condition.Bool."aws:SecureTransport" == "false" | not))' 2>/dev/null | wc -l)

    # Check for overly permissive actions
    local wildcard_actions
    wildcard_actions=$(echo "${policy_text}" | jq '.Statement[]? | select(.Effect=="Allow" and (.Action == "s3:*" or (.Action | type == "array" and . | contains(["s3:*"]))))' 2>/dev/null | wc -l)

    if (( allows_http > 0 || wildcard_actions > 0 )); then
      {
        echo "Bucket: ${bucket_name}"
      } >> "${OUTPUT_FILE}"

      if (( allows_http > 0 )); then
        ((insecure_transport++))
        echo "  WARNING: Policy may allow insecure (HTTP) transport" >> "${OUTPUT_FILE}"
      fi

      if (( wildcard_actions > 0 )); then
        ((overly_permissive++))
        echo "  WARNING: Policy contains wildcard actions (s3:*)" >> "${OUTPUT_FILE}"
      fi

      echo "" >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo "Policy Audit Summary:"
    echo "  Insecure Transport: ${insecure_transport}"
    echo "  Overly Permissive: ${overly_permissive}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local no_versioning="$2"; local no_encryption="$3"; local public="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS S3 Bucket Compliance Audit Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Total Buckets", "value": "${total}", "short": true},
        {"title": "No Versioning", "value": "${no_versioning}", "short": true},
        {"title": "No Encryption", "value": "${no_encryption}", "short": true},
        {"title": "Public Access", "value": "${public}", "short": true},
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
  log_message INFO "Starting AWS S3 bucket compliance audit"
  write_header
  report_buckets
  audit_public_buckets
  audit_bucket_policies
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total no_versioning no_encryption public
  total=$(grep "Total:" "${OUTPUT_FILE}" | grep "Bucket Summary" -A1 | tail -1 | awk '{print $NF}')
  no_versioning=$(grep "Versioning Disabled:" "${OUTPUT_FILE}" | awk '{print $NF}')
  no_encryption=$(grep "Unencrypted:" "${OUTPUT_FILE}" | awk '{print $NF}')
  public=$(grep "Publicly Accessible:" "${OUTPUT_FILE}" | awk '{print $NF}')
  send_slack_alert "${total}" "${no_versioning}" "${no_encryption}" "${public}"
  cat "${OUTPUT_FILE}"
}

main "$@"
