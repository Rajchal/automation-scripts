#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-waf-acl-auditor.log"
REPORT_FILE="/tmp/waf-acl-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS WAF ACL Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_web_acl() {
  local acl_arn="$1"
  local acl_name="$2"

  echo "WebACL: $acl_name ($acl_arn)" >> "$REPORT_FILE"

  # Check associations
  assoc_count=$(aws wafv2 list-resources-for-web-acl --web-acl-arn "$acl_arn" --scope REGIONAL --output json 2>/dev/null | jq -r '.ResourceArns | length')
  if [ "$assoc_count" -eq 0 ]; then
    echo "  UNASSOCIATED: $acl_name has no associated resources" >> "$REPORT_FILE"
    send_slack_alert "WAF Alert: WebACL $acl_name is not associated with any resource"
  fi

  # Check logging configuration
  logging=$(aws wafv2 get-logging-configuration --resource-arn "$acl_arn" --scope REGIONAL 2>/dev/null || true)
  if [ -z "$logging" ] || [ "$(echo "$logging" | jq -r '.LoggingConfiguration // empty')" = "" ]; then
    echo "  LOGGING_DISABLED: $acl_name has no logging configuration" >> "$REPORT_FILE"
    send_slack_alert "WAF Alert: WebACL $acl_name has no logging configuration"
  fi

  # Check rules for overly permissive rule statements
  aws wafv2 get-web-acl --name "$acl_name" --scope REGIONAL --id "$acl_arn" --output json 2>/dev/null | jq -c '.WebACL.Rules[]? // empty' | while read -r r; do
    rname=$(echo "$r" | jq -r '.Name // "<unnamed>"')
    priority=$(echo "$r" | jq -r '.Priority // "-"')
    action=$(echo "$r" | jq -r '.Action | keys_unsorted[0] // ""')
    stmt=$(echo "$r" | jq -c '.Statement')

    if echo "$stmt" | jq -e 'has("managedRuleGroupStatement")' >/dev/null 2>&1; then
      echo "  Rule: $rname (managed) priority=$priority action=$action" >> "$REPORT_FILE"
      continue
    fi

    # Example heuristic: if rule has ByteMatch or IPSet with empty values, flag
    if echo "$stmt" | jq -e '(.IPSetReferenceStatement? // "") == "" and (.ByteMatchStatement? // "") == ""' >/dev/null 2>&1; then
      echo "  Rule: $rname may be permissive or misconfigured (priority=$priority action=$action)" >> "$REPORT_FILE"
      send_slack_alert "WAF Alert: Rule $rname in $acl_name may be permissive or misconfigured"
    fi
  done

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  # list regional and global scopes
  for scope in REGIONAL CLOUDFRONT; do
    aws wafv2 list-web-acls --scope "$scope" --output json 2>/dev/null | jq -c '.WebACLs[]? // empty' | while read -r acl; do
      name=$(echo "$acl" | jq -r '.Name')
      arn=$(echo "$acl" | jq -r '.ARN')
      check_web_acl "$arn" "$name"
    done
  done

  log_message "WAF ACL audit written to $REPORT_FILE"
}

main "$@"
