#!/bin/bash

################################################################################
# AWS CloudFront Distribution Audit
# Audits CloudFront distributions for caching, security, and configuration issues
################################################################################

set -euo pipefail

# Configuration
OUTPUT_FILE="/tmp/cloudfront-audit-$(date +%s).txt"
LOG_FILE="/var/log/cloudfront-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

################################################################################
# Logging
################################################################################
log_message() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%dT%H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

################################################################################
# Get all CloudFront distributions
################################################################################
get_distributions() {
    aws cloudfront list-distributions \
        --query 'DistributionList.Items[*].[Id,DomainName,Status,Enabled,Comment,DefaultCacheBehavior.ViewerProtocolPolicy]' \
        --output text 2>/dev/null || {
        log_message "ERROR" "Failed to fetch CloudFront distributions"
        return 1
    }
}

################################################################################
# Get distribution details
################################################################################
get_distribution_config() {
    local dist_id="$1"
    
    aws cloudfront get-distribution-config \
        --id "${dist_id}" \
        --query 'DistributionConfig' \
        --output json 2>/dev/null || echo "ERROR"
}

################################################################################
# Audit HTTP to HTTPS redirects
################################################################################
audit_https_enforcement() {
    log_message "INFO" "Auditing HTTPS enforcement..."
    
    {
        echo ""
        echo "=== HTTPS ENFORCEMENT CHECK ==="
    } >> "${OUTPUT_FILE}"
    
    local http_only_count=0
    
    while IFS=$'\t' read -r dist_id domain_name status enabled comment protocol; do
        if [[ "${protocol}" != "https-only" ]]; then
            ((http_only_count++))
            {
                echo "Distribution: ${domain_name} (${dist_id})"
                echo "  Protocol Policy: ${protocol}"
                echo "  Status: ISSUE - Should enforce HTTPS"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_distributions)
    
    if [[ ${http_only_count} -gt 0 ]]; then
        log_message "WARN" "Found ${http_only_count} distributions not enforcing HTTPS"
    fi
}

################################################################################
# Audit caching policies
################################################################################
audit_caching_policies() {
    log_message "INFO" "Auditing caching policies..."
    
    {
        echo ""
        echo "=== CACHING POLICY ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r dist_id domain_name status enabled comment _; do
        if [[ "${enabled}" == "true" ]]; then
            local config=$(get_distribution_config "${dist_id}")
            
            if [[ "${config}" != "ERROR" ]]; then
                local cache_behaviors=$(echo "${config}" | jq '.CacheBehaviors | length' 2>/dev/null || echo "0")
                local default_ttl=$(echo "${config}" | jq '.DefaultCacheBehavior.DefaultTTL' 2>/dev/null || echo "N/A")
                local max_ttl=$(echo "${config}" | jq '.DefaultCacheBehavior.MaxTTL' 2>/dev/null || echo "N/A")
                
                {
                    echo "Distribution: ${domain_name}"
                    echo "  Cache Behaviors: ${cache_behaviors}"
                    echo "  Default TTL: ${default_ttl}s"
                    echo "  Max TTL: ${max_ttl}s"
                    echo ""
                } >> "${OUTPUT_FILE}"
            fi
        fi
    done < <(get_distributions)
}

################################################################################
# Audit disabled distributions
################################################################################
audit_disabled_distributions() {
    log_message "INFO" "Checking for disabled distributions..."
    
    {
        echo ""
        echo "=== DISABLED DISTRIBUTIONS ==="
    } >> "${OUTPUT_FILE}"
    
    local disabled_count=0
    
    while IFS=$'\t' read -r dist_id domain_name status enabled comment _; do
        if [[ "${enabled}" == "false" ]]; then
            ((disabled_count++))
            {
                echo "Distribution: ${domain_name} (${dist_id})"
                echo "  Status: DISABLED"
                echo "  Cloudfront Status: ${status}"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_distributions)
    
    if [[ ${disabled_count} -gt 0 ]]; then
        log_message "INFO" "Found ${disabled_count} disabled distributions"
    fi
}

################################################################################
# Audit origin security
################################################################################
audit_origin_security() {
    log_message "INFO" "Auditing origin security configurations..."
    
    {
        echo ""
        echo "=== ORIGIN SECURITY AUDIT ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r dist_id domain_name _ _ _ _; do
        local config=$(get_distribution_config "${dist_id}")
        
        if [[ "${config}" != "ERROR" ]]; then
            local origin_protocol=$(echo "${config}" | jq '.Origins[0].CustomOriginConfig.OriginProtocolPolicy' 2>/dev/null || echo "N/A")
            
            if [[ "${origin_protocol}" == "http-only" ]]; then
                {
                    echo "Distribution: ${domain_name} (${dist_id})"
                    echo "  WARNING: Origin uses HTTP (unencrypted)"
                    echo ""
                } >> "${OUTPUT_FILE}"
            fi
        fi
    done < <(get_distributions)
}

################################################################################
# Audit WAF integration
################################################################################
audit_waf_integration() {
    log_message "INFO" "Auditing WAF integration..."
    
    {
        echo ""
        echo "=== WAF INTEGRATION STATUS ==="
    } >> "${OUTPUT_FILE}"
    
    local waf_count=0
    local no_waf_count=0
    
    while IFS=$'\t' read -r dist_id domain_name status enabled _ _; do
        if [[ "${enabled}" == "true" ]]; then
            local config=$(get_distribution_config "${dist_id}")
            
            if [[ "${config}" != "ERROR" ]]; then
                local waf_id=$(echo "${config}" | jq '.WebACLId' 2>/dev/null || echo "")
                
                if [[ -n "${waf_id}" ]] && [[ "${waf_id}" != "null" ]]; then
                    ((waf_count++))
                else
                    ((no_waf_count++))
                    echo "Distribution without WAF: ${domain_name}" >> "${OUTPUT_FILE}"
                fi
            fi
        fi
    done < <(get_distributions)
    
    {
        echo "Distributions with WAF: ${waf_count}"
        echo "Distributions without WAF: ${no_waf_count}"
        echo ""
    } >> "${OUTPUT_FILE}"
    
    if [[ ${no_waf_count} -gt 0 ]]; then
        log_message "WARN" "Found ${no_waf_count} distributions without WAF"
    fi
}

################################################################################
# Audit geo-restriction
################################################################################
audit_geo_restriction() {
    log_message "INFO" "Auditing geo-restriction policies..."
    
    {
        echo ""
        echo "=== GEO-RESTRICTION POLICIES ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r dist_id domain_name _ _ _ _; do
        local config=$(get_distribution_config "${dist_id}")
        
        if [[ "${config}" != "ERROR" ]]; then
            local geo_enabled=$(echo "${config}" | jq '.Restrictions.GeoRestriction.RestrictionType' 2>/dev/null || echo "none")
            
            if [[ "${geo_enabled}" != "none" ]]; then
                local countries=$(echo "${config}" | jq '.Restrictions.GeoRestriction.Items | length' 2>/dev/null || echo "0")
                {
                    echo "Distribution: ${domain_name}"
                    echo "  Restriction Type: ${geo_enabled}"
                    echo "  Countries: ${countries}"
                    echo ""
                } >> "${OUTPUT_FILE}"
            fi
        fi
    done < <(get_distributions)
}

################################################################################
# Send Slack notification
################################################################################
send_slack_alert() {
    local findings="$1"
    
    [[ -z "${SLACK_WEBHOOK}" ]] && return 0
    
    local payload=$(cat <<EOF
{
    "text": "CloudFront Distribution Audit",
    "attachments": [
        {
            "color": "warning",
            "fields": [
                {"title": "Issues Found", "value": "${findings}", "short": true},
                {"title": "Timestamp", "value": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "short": true}
            ]
        }
    ]
}
EOF
)
    
    curl -X POST -H 'Content-type: application/json' \
        --data "${payload}" \
        "${SLACK_WEBHOOK}" 2>/dev/null || log_message "WARN" "Failed to send Slack alert"
}

################################################################################
# Main audit logic
################################################################################
main() {
    log_message "INFO" "Starting CloudFront distribution audit"
    
    {
        echo "AWS CloudFront Distribution Audit Report"
        echo "========================================"
        echo "Generated: $(date)"
    } > "${OUTPUT_FILE}"
    
    audit_https_enforcement
    audit_caching_policies
    audit_disabled_distributions
    audit_origin_security
    audit_waf_integration
    audit_geo_restriction
    
    log_message "INFO" "Audit complete. Report saved to: ${OUTPUT_FILE}"
    
    # Count issues for notification
    local issue_count=$(grep -c "WARNING\|ISSUE\|without" "${OUTPUT_FILE}" || echo "0")
    
    if [[ ${issue_count} -gt 0 ]]; then
        send_slack_alert "${issue_count}"
    fi
    
    cat "${OUTPUT_FILE}"
}

main "$@"
