#!/bin/bash

################################################################################
# AWS Systems Manager Parameter Store Checker
# Audits parameters, checks for stale values, unused parameters, and security issues
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
DAYS_STALE="${DAYS_STALE:-90}"
OUTPUT_FILE="/tmp/ssm-param-audit-$(date +%s).txt"
LOG_FILE="/var/log/ssm-param-checker.log"
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
# Get all parameters
################################################################################
get_parameters() {
    aws ssm describe-parameters \
        --region "${REGION}" \
        --query 'Parameters[*].[Name,Type,LastModifiedDate,Version]' \
        --output text 2>/dev/null || {
        log_message "ERROR" "Failed to fetch parameters"
        return 1
    }
}

################################################################################
# Get parameter metadata
################################################################################
get_parameter_metadata() {
    local param_name="$1"
    
    aws ssm get-parameter \
        --name "${param_name}" \
        --region "${REGION}" \
        --query 'Parameter.[Name,Type,Value,Version,LastModifiedDate,ARN]' \
        --output text 2>/dev/null || echo "ERROR"
}

################################################################################
# Check for stale parameters
################################################################################
audit_stale_parameters() {
    log_message "INFO" "Checking for stale parameters (not modified in ${DAYS_STALE} days)"
    
    {
        echo ""
        echo "=== STALE PARAMETERS (Not Modified in ${DAYS_STALE} Days) ==="
    } >> "${OUTPUT_FILE}"
    
    local stale_count=0
    local cutoff_date=$(date -d "${DAYS_STALE} days ago" +%s)
    
    while IFS=$'\t' read -r param_name param_type last_modified version; do
        # Parse date - AWS returns ISO format
        local mod_timestamp=$(date -d "${last_modified}" +%s 2>/dev/null || echo "0")
        
        if [[ ${mod_timestamp} -lt ${cutoff_date} ]]; then
            ((stale_count++))
            {
                echo "Parameter: ${param_name}"
                echo "  Type: ${param_type}"
                echo "  Last Modified: ${last_modified}"
                echo "  Version: ${version}"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_parameters)
    
    if [[ ${stale_count} -gt 0 ]]; then
        log_message "WARN" "Found ${stale_count} stale parameters"
    fi
}

################################################################################
# Check for SecureString parameter security
################################################################################
audit_securestring_parameters() {
    log_message "INFO" "Auditing SecureString parameters..."
    
    {
        echo ""
        echo "=== SECURESTRING PARAMETERS ==="
    } >> "${OUTPUT_FILE}"
    
    local securestring_count=0
    
    while IFS=$'\t' read -r param_name param_type _ _; do
        if [[ "${param_type}" == "SecureString" ]]; then
            ((securestring_count++))
            {
                echo "Parameter: ${param_name}"
                echo "  Type: SecureString (Encrypted)"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_parameters)
    
    log_message "INFO" "Found ${securestring_count} SecureString parameters"
}

################################################################################
# Check parameter naming conventions
################################################################################
audit_naming_conventions() {
    log_message "INFO" "Auditing parameter naming conventions..."
    
    {
        echo ""
        echo "=== NAMING CONVENTION ISSUES ==="
    } >> "${OUTPUT_FILE}"
    
    local convention_issues=0
    
    while IFS=$'\t' read -r param_name _ _ _; do
        # Check for spaces
        if [[ "${param_name}" == *" "* ]]; then
            ((convention_issues++))
            echo "Parameter: ${param_name} - Contains spaces" >> "${OUTPUT_FILE}"
        fi
        
        # Check for /app/service naming pattern
        if ! [[ "${param_name}" =~ ^/[a-z0-9\-/_]+$ ]]; then
            ((convention_issues++))
            echo "Parameter: ${param_name} - Non-standard naming pattern" >> "${OUTPUT_FILE}"
        fi
    done < <(get_parameters)
    
    if [[ ${convention_issues} -gt 0 ]]; then
        log_message "WARN" "Found ${convention_issues} naming convention issues"
    fi
}

################################################################################
# Check for unused parameters
################################################################################
audit_unused_parameters() {
    log_message "INFO" "Analyzing parameter usage patterns..."
    
    {
        echo ""
        echo "=== PARAMETER USAGE ANALYSIS ==="
        echo "Parameters with version 1 (possibly unused):"
    } >> "${OUTPUT_FILE}"
    
    local unused_count=0
    
    while IFS=$'\t' read -r param_name _ _ version; do
        if [[ "${version}" == "1" ]]; then
            ((unused_count++))
            echo "  - ${param_name}" >> "${OUTPUT_FILE}"
        fi
    done < <(get_parameters)
    
    if [[ ${unused_count} -gt 0 ]]; then
        log_message "INFO" "Found ${unused_count} parameters with version 1 (possible candidates for review)"
    fi
}

################################################################################
# Check for parameter naming patterns
################################################################################
audit_by_tier() {
    log_message "INFO" "Analyzing parameters by tier..."
    
    {
        echo ""
        echo "=== PARAMETERS BY TIER ==="
    } >> "${OUTPUT_FILE}"
    
    local standard_count=0
    local advanced_count=0
    local intelligent_count=0
    
    while IFS=$'\t' read -r _ param_type _ _; do
        if [[ "${param_type}" == "String" ]]; then
            ((standard_count++))
        elif [[ "${param_type}" == "SecureString" ]]; then
            ((advanced_count++))
        elif [[ "${param_type}" == "StringList" ]]; then
            ((intelligent_count++))
        fi
    done < <(get_parameters)
    
    {
        echo "String Parameters: ${standard_count}"
        echo "SecureString Parameters: ${advanced_count}"
        echo "StringList Parameters: ${intelligent_count}"
        echo ""
    } >> "${OUTPUT_FILE}"
}

################################################################################
# Send Slack notification
################################################################################
send_slack_alert() {
    local findings="$1"
    
    [[ -z "${SLACK_WEBHOOK}" ]] && return 0
    
    local payload=$(cat <<EOF
{
    "text": "SSM Parameter Store Audit",
    "attachments": [
        {
            "color": "warning",
            "fields": [
                {"title": "Region", "value": "${REGION}", "short": true},
                {"title": "Issues Found", "value": "${findings}", "short": true},
                {"title": "Stale Period", "value": "${DAYS_STALE} days", "short": true},
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
    log_message "INFO" "Starting SSM Parameter Store audit"
    
    {
        echo "AWS Systems Manager Parameter Store Audit"
        echo "=========================================="
        echo "Generated: $(date)"
        echo "Region: ${REGION}"
        echo "Stale Threshold: ${DAYS_STALE} days"
    } > "${OUTPUT_FILE}"
    
    audit_stale_parameters
    audit_securestring_parameters
    audit_naming_conventions
    audit_unused_parameters
    audit_by_tier
    
    log_message "INFO" "Audit complete. Report saved to: ${OUTPUT_FILE}"
    
    # Count issues for notification
    local issue_count=$(grep -c "WARNING\|ERROR\|Found\|Issues" "${OUTPUT_FILE}" || echo "0")
    
    if [[ ${issue_count} -gt 0 ]]; then
        send_slack_alert "${issue_count}"
    fi
    
    cat "${OUTPUT_FILE}"
}

main "$@"
