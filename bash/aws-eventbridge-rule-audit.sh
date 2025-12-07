#!/bin/bash

################################################################################
# AWS EventBridge Rule Audit
# Audits EventBridge rules for disabled rules, orphaned rules, and configuration issues
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/eventbridge-audit-$(date +%s).txt"
LOG_FILE="/var/log/eventbridge-audit.log"
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
# Get all EventBridge rules
################################################################################
get_eventbridge_rules() {
    aws events list-rules \
        --region "${REGION}" \
        --query 'Rules[*].[Name,State,Description,EventPattern,ScheduleExpression]' \
        --output text 2>/dev/null || {
        log_message "ERROR" "Failed to fetch EventBridge rules"
        return 1
    }
}

################################################################################
# Get rule targets
################################################################################
get_rule_targets() {
    local rule_name="$1"
    
    aws events list-targets-by-rule \
        --rule "${rule_name}" \
        --region "${REGION}" \
        --query 'Targets[*].[Id,Arn,State]' \
        --output text 2>/dev/null || echo "ERROR"
}

################################################################################
# Check for disabled rules
################################################################################
audit_disabled_rules() {
    log_message "INFO" "Checking for disabled rules..."
    
    local disabled_count=0
    
    {
        echo ""
        echo "=== DISABLED RULES ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r rule_name state description event_pattern schedule; do
        if [[ "${state}" == "DISABLED" ]]; then
            ((disabled_count++))
            {
                echo "Rule: ${rule_name}"
                echo "  State: ${state}"
                echo "  Description: ${description:-N/A}"
                echo "  Schedule: ${schedule:-N/A}"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_eventbridge_rules)
    
    if [[ ${disabled_count} -gt 0 ]]; then
        log_message "WARN" "Found ${disabled_count} disabled EventBridge rules"
    fi
}

################################################################################
# Check for orphaned targets
################################################################################
audit_orphaned_targets() {
    log_message "INFO" "Checking for orphaned rule targets..."
    
    {
        echo ""
        echo "=== RULES WITHOUT TARGETS ==="
    } >> "${OUTPUT_FILE}"
    
    local orphaned_count=0
    
    while IFS=$'\t' read -r rule_name state description _ _; do
        local targets=$(get_rule_targets "${rule_name}")
        
        if [[ "${targets}" == "ERROR" ]] || [[ -z "${targets}" ]]; then
            ((orphaned_count++))
            {
                echo "Rule: ${rule_name}"
                echo "  Status: No targets configured"
                echo "  State: ${state}"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_eventbridge_rules)
    
    if [[ ${orphaned_count} -gt 0 ]]; then
        log_message "WARN" "Found ${orphaned_count} rules without targets"
    fi
}

################################################################################
# Check rule pattern validity
################################################################################
audit_rule_patterns() {
    log_message "INFO" "Auditing rule event patterns..."
    
    {
        echo ""
        echo "=== RULE PATTERN ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r rule_name state description event_pattern schedule; do
        # Check if rule has both pattern and schedule (unusual but valid)
        if [[ -n "${event_pattern}" ]] && [[ -n "${schedule}" ]]; then
            {
                echo "Rule: ${rule_name}"
                echo "  WARNING: Has both EventPattern and ScheduleExpression"
                echo "  EventPattern: ${event_pattern}"
                echo "  Schedule: ${schedule}"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
        
        # Check for empty patterns
        if [[ -z "${event_pattern}" ]] && [[ -z "${schedule}" ]]; then
            {
                echo "Rule: ${rule_name}"
                echo "  WARNING: No event pattern or schedule defined"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_eventbridge_rules)
}

################################################################################
# Check for old disabled rules that could be deleted
################################################################################
audit_cleanup_candidates() {
    log_message "INFO" "Identifying cleanup candidates..."
    
    {
        echo ""
        echo "=== CLEANUP CANDIDATES ==="
        echo "Disabled rules that might be removed:"
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r rule_name state description _ _; do
        if [[ "${state}" == "DISABLED" ]]; then
            # Get creation time would require additional API call
            # For now, just list disabled rules
            echo "  - ${rule_name}" >> "${OUTPUT_FILE}"
        fi
    done < <(get_eventbridge_rules)
}

################################################################################
# Send Slack notification
################################################################################
send_slack_alert() {
    local findings_count="$1"
    
    [[ -z "${SLACK_WEBHOOK}" ]] && return 0
    
    local payload=$(cat <<EOF
{
    "text": "EventBridge Audit Report",
    "attachments": [
        {
            "color": "warning",
            "fields": [
                {"title": "Region", "value": "${REGION}", "short": true},
                {"title": "Findings", "value": "${findings_count}", "short": true},
                {"title": "Timestamp", "value": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "short": false}
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
    log_message "INFO" "Starting EventBridge rule audit"
    
    {
        echo "EventBridge Rule Audit Report"
        echo "=============================="
        echo "Generated: $(date)"
        echo "Region: ${REGION}"
    } > "${OUTPUT_FILE}"
    
    audit_disabled_rules
    audit_orphaned_targets
    audit_rule_patterns
    audit_cleanup_candidates
    
    log_message "INFO" "Audit complete. Report saved to: ${OUTPUT_FILE}"
    
    # Count issues for notification
    local issue_count=$(grep -c "WARNING\|ERROR" "${OUTPUT_FILE}" || echo "0")
    
    if [[ ${issue_count} -gt 0 ]]; then
        send_slack_alert "${issue_count}"
    fi
    
    cat "${OUTPUT_FILE}"
}

main "$@"
