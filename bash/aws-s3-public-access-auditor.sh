#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-s3-public-access-auditor.log"
REPORT_FILE="/tmp/s3-public-access-auditor-$(date +%Y%m%d%H%M%S).txt"

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
  echo "S3 Public Access Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

is_policy_public() {
  # simple heuristic: policy contains Principal": "*" or "Allow" with Principal *
  local policy_json="$1"
  if [ -z "$policy_json" ] || [ "$policy_json" = "{}" ]; then
    return 1
  fi
  echo "$policy_json" | jq -e '(.Statement[]? | select(.Effect=="Allow") | .Principal) as $p | ($p == "*" ) or ($p.AWS == "*") or ($p == {"AWS":"*"})' >/dev/null 2>&1 && return 0 || return 1
}

main() {
  write_header

  buckets_json=$(aws s3api list-buckets --output json --region "$REGION" 2>/dev/null || echo '{"Buckets":[]}')
  buckets=$(echo "$buckets_json" | jq -r '.Buckets[].Name')

  if [ -z "$buckets" ]; then
    echo "No S3 buckets found." >> "$REPORT_FILE"
    log_message "No S3 buckets"
    exit 0
  fi

  total=0
  issues=0

  for b in $buckets; do
    total=$((total+1))
    echo "Bucket: $b" >> "$REPORT_FILE"

    pab_json=$(aws s3api get-public-access-block --bucket "$b" --region "$REGION" --output json 2>/dev/null || echo '{}')
    pab_exists=true
    if [ "$pab_json" = "{}" ]; then
      pab_exists=false
    fi

    block_public_acls=$(echo "$pab_json" | jq -r '.PublicAccessBlockConfiguration.BlockPublicAcls // false')
    block_public_policy=$(echo "$pab_json" | jq -r '.PublicAccessBlockConfiguration.BlockPublicPolicy // false')

    echo "  PublicAccessBlock present: $pab_exists" >> "$REPORT_FILE"
    echo "  BlockPublicAcls: ${block_public_acls}" >> "$REPORT_FILE"
    echo "  BlockPublicPolicy: ${block_public_policy}" >> "$REPORT_FILE"

    # Check ACL grants
    acl_json=$(aws s3api get-bucket-acl --bucket "$b" --region "$REGION" --output json 2>/dev/null || echo '{}')
    public_acl=false
    if echo "$acl_json" | jq -e '.Grants[]? | .Grantee.URI? | contains("AllUsers") or contains("AuthenticatedUsers")' >/dev/null 2>&1; then
      public_acl=true
    fi
    echo "  Public ACL: $public_acl" >> "$REPORT_FILE"

    # Check bucket policy
    policy_json=$(aws s3api get-bucket-policy --bucket "$b" --region "$REGION" --output json 2>/dev/null || echo '{}')
    policy_public=false
    if is_policy_public "$policy_json"; then
      policy_public=true
    fi
    echo "  Policy allows public: $policy_public" >> "$REPORT_FILE"

    # Check policy status if available
    policy_status_json=$(aws s3api get-bucket-policy-status --bucket "$b" --region "$REGION" --output json 2>/dev/null || echo '{}')
    is_public_bucket_status=$(echo "$policy_status_json" | jq -r '.PolicyStatus.IsPublic // false')
    echo "  PolicyStatus.IsPublic: ${is_public_bucket_status}" >> "$REPORT_FILE"

    echo "" >> "$REPORT_FILE"

    if [ "$public_acl" = true ] || [ "$policy_public" = true ] || [ "$is_public_bucket_status" = true ] || [ "$block_public_policy" != true ]; then
      send_slack_alert "S3 Alert: Bucket $b may be public (acl=$public_acl policy_public=$policy_public policyStatusIsPublic=$is_public_bucket_status blockPublicPolicy=$block_public_policy)."
      issues=$((issues+1))
    fi
  done

  echo "Summary: total_buckets=$total, issues=$issues" >> "$REPORT_FILE"
  log_message "S3 public access report written to $REPORT_FILE (total_buckets=$total, issues=$issues)"
}

main "$@"
