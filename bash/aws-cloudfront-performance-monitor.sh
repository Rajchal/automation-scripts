#!/bin/bash

################################################################################
# AWS CloudFront Performance Monitor
# Audits CloudFront distributions: config posture (origins, HTTPS only,
# origin failover, WAF assoc, logging, geo/block settings), and pulls
# CloudWatch metrics (Requests, BytesDownloaded/Uploaded, TotalErrorRate,
# 4xxErrorRate, 5xxErrorRate, Latency/P99 if available via metric math/SO?).
# Includes thresholds, logging, Slack/email alerts, and a text report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"  # CloudFront metrics are in us-east-1
OUTPUT_FILE="/tmp/cloudfront-performance-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/cloudfront-performance-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds (override via env)
ERROR_RATE_WARN_PCT="${ERROR_RATE_WARN_PCT:-1}"     # total error rate
ERROR_5XX_WARN_PCT="${ERROR_5XX_WARN_PCT:-0.5}"     # 5xx error rate
LATENCY_P99_WARN_MS="${LATENCY_P99_WARN_MS:-800}"   # edge latency p99 (if available)
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_DISTS=0
DISTS_WITH_ISSUES=0
DISTS_HIGH_ERROR=0
DISTS_HIGH_5XX=0
DISTS_HIGH_LATENCY=0
DISTS_INSECURE_ORIGIN=0
DISTS_NO_WAF=0

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
      "title": "AWS CloudFront Alert",
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
    echo "AWS CloudFront Performance Monitor"
    echo "=================================="
    echo "Generated: $(date)"
    echo "Region (metrics): ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Total Error Rate Warning: > ${ERROR_RATE_WARN_PCT}%"
    echo "  5xx Error Rate Warning: > ${ERROR_5XX_WARN_PCT}%"
    echo "  Latency p99 Warning: > ${LATENCY_P99_WARN_MS}ms (if available)"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_distributions() {
  aws_cmd cloudfront list-distributions --output json 2>/dev/null || echo '{"DistributionList":{"Items":[]}}'
}

get_distribution() {
  local id="$1"
  aws_cmd cloudfront get-distribution --id "$id" --output json 2>/dev/null || echo '{}'
}

get_metrics() {
  local dist_id="$1" metric="$2" stat_type="${3:-Average}"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/CloudFront \
    --metric-name "$metric" \
    --dimensions Name=DistributionId,Value="$dist_id" Name=Region,Value="Global" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics "$stat_type" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.4f", s/c; else print "0"}'; }
calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {if(NR==0) print 0; else printf "%.0f", s}'; }
calculate_p() { local p="$1"; jq -r ".Datapoints[].p${p}" 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }

record_issue() {
  ISSUES+=("$1")
}

analyze_distribution() {
  local dist_json="$1"
  local id domain enabled status
  id=$(echo "${dist_json}" | jq_safe '.Id')
  domain=$(echo "${dist_json}" | jq_safe '.DomainName')
  enabled=$(echo "${dist_json}" | jq_safe '.Enabled')
  status=$(echo "${dist_json}" | jq_safe '.Status')

  TOTAL_DISTS=$((TOTAL_DISTS + 1))
  log_message INFO "Analyzing CloudFront distribution ${id} (${domain})"

  {
    echo "Distribution: ${id}"
    echo "  Domain: ${domain}"
    echo "  Enabled: ${enabled}"
    echo "  Status: ${status}"
  } >> "${OUTPUT_FILE}"

  # Origins HTTPS check and failover
  local origins insecure_count failover_count
  origins=$(echo "${dist_json}" | jq -c '.Origins.Items[]?')
  insecure_count=$(echo "${origins}" | jq -r 'select(.CustomOriginConfig) | select(.CustomOriginConfig.OriginProtocolPolicy != "https-only") | .Id' | wc -l)
  failover_count=$(echo "${origins}" | jq -r 'select(.OriginShield) | .Id' | wc -l)
  echo "  Origins: $(echo "${dist_json}" | jq -r '.Origins.Items | length') (insecure: ${insecure_count}, failover: ${failover_count})" >> "${OUTPUT_FILE}"
  if (( insecure_count > 0 )); then
    DISTS_INSECURE_ORIGIN=$((DISTS_INSECURE_ORIGIN + 1))
    record_issue "CloudFront ${id} has origins not enforcing https-only"
  fi

  # WAF association
  local waf
  waf=$(echo "${dist_json}" | jq_safe '.WebACLId')
  [[ -z "${waf}" || "${waf}" == "null" ]] && { DISTS_NO_WAF=$((DISTS_NO_WAF + 1)); record_issue "CloudFront ${id} has no WAF"; }

  # Logging
  local logging
  logging=$(echo "${dist_json}" | jq_safe '.Logging.Bucket')
  echo "  Logging Bucket: ${logging:-none}" >> "${OUTPUT_FILE}"

  # Viewer certificate
  local viewer_cert
  viewer_cert=$(echo "${dist_json}" | jq_safe '.ViewerCertificate.ACMCertificateArn // .ViewerCertificate.CloudFrontDefaultCertificate // ""')
  echo "  Viewer Certificate: ${viewer_cert}" >> "${OUTPUT_FILE}"

  # Geo restrictions
  local geo
  geo=$(echo "${dist_json}" | jq_safe '.Restrictions.GeoRestriction.RestrictionType')
  echo "  Geo Restriction: ${geo}" >> "${OUTPUT_FILE}"

  # Metrics
  local requests bytes_down bytes_up err_rate err_4xx err_5xx latency_p99
  requests=$(get_metrics "$id" "Requests" "Sum" | calculate_sum)
  bytes_down=$(get_metrics "$id" "BytesDownloaded" "Sum" | calculate_sum)
  bytes_up=$(get_metrics "$id" "BytesUploaded" "Sum" | calculate_sum)
  err_rate=$(get_metrics "$id" "TotalErrorRate" "Average" | calculate_avg)
  err_4xx=$(get_metrics "$id" "4xxErrorRate" "Average" | calculate_avg)
  err_5xx=$(get_metrics "$id" "5xxErrorRate" "Average" | calculate_avg)
  latency_p99=$(get_metrics "$id" "Latency" "p99" | calculate_p 99)

  {
    echo "  Metrics (${LOOKBACK_HOURS}h):"
    echo "    Requests: ${requests}"
    echo "    Bytes Down: ${bytes_down}"
    echo "    Bytes Up: ${bytes_up}"
    echo "    Error Rate (total): ${err_rate}%"
    echo "    4xx Error Rate: ${err_4xx}%"
    echo "    5xx Error Rate: ${err_5xx}%"
    echo "    Latency p99: ${latency_p99} ms"
  } >> "${OUTPUT_FILE}"

  local dist_issue=0

  if (( $(echo "${err_rate} > ${ERROR_RATE_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    DISTS_HIGH_ERROR=$((DISTS_HIGH_ERROR + 1))
    dist_issue=1
    record_issue "CloudFront ${id} total error rate ${err_rate}% exceeds ${ERROR_RATE_WARN_PCT}%"
  fi

  if (( $(echo "${err_5xx} > ${ERROR_5XX_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    DISTS_HIGH_5XX=$((DISTS_HIGH_5XX + 1))
    dist_issue=1
    record_issue "CloudFront ${id} 5xx error rate ${err_5xx}% exceeds ${ERROR_5XX_WARN_PCT}%"
  fi

  if (( $(echo "${latency_p99} > ${LATENCY_P99_WARN_MS}" | bc -l 2>/dev/null || echo 0) )); then
    DISTS_HIGH_LATENCY=$((DISTS_HIGH_LATENCY + 1))
    dist_issue=1
    record_issue "CloudFront ${id} latency p99 ${latency_p99}ms exceeds ${LATENCY_P99_WARN_MS}ms"
  fi

  if (( dist_issue )); then
    DISTS_WITH_ISSUES=$((DISTS_WITH_ISSUES + 1))
  fi

  echo "" >> "${OUTPUT_FILE}"
}

main() {
  write_header
  local list_json
  list_json=$(list_distributions)
  local dist_count
  dist_count=$(echo "${list_json}" | jq -r '.DistributionList.Items | length')

  if [[ "${dist_count}" == "0" ]]; then
    log_message WARN "No CloudFront distributions found"
    echo "No CloudFront distributions found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total Distributions: ${dist_count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  while read -r dist; do
    analyze_distribution "${dist}"
  done <<< "$(echo "${list_json}" | jq -c '.DistributionList.Items[]')"

  {
    echo "Summary"
    echo "-------"
    echo "Total Distributions: ${TOTAL_DISTS}"
    echo "Distributions with Issues: ${DISTS_WITH_ISSUES}"
    echo "High Error Rate: ${DISTS_HIGH_ERROR}"
    echo "High 5xx Rate: ${DISTS_HIGH_5XX}"
    echo "High Latency: ${DISTS_HIGH_LATENCY}"
    echo "Insecure Origins: ${DISTS_INSECURE_ORIGIN}"
    echo "Missing WAF: ${DISTS_NO_WAF}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "CloudFront Performance Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "CloudFront Performance Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"
