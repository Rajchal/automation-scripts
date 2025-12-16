#!/bin/bash

################################################################################
# AWS Step Functions Auditor
# Audits Step Functions state machines, executions, and failure patterns
# Detects failed executions, timeout issues, and performance bottlenecks
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/stepfunctions-audit-$(date +%s).txt"
LOG_FILE="/var/log/stepfunctions-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DAYS_BACK="${DAYS_BACK:-7}"
FAILED_THRESHOLD="${FAILED_THRESHOLD:-5}"

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
# Get all Step Functions state machines
################################################################################
get_state_machines() {
    aws stepfunctions list-state-machines \
        --region "${REGION}" \
        --query 'stateMachines[*].[stateMachineArn,name,type,creationDate]' \
        --output text 2>/dev/null || {
        log_message "ERROR" "Failed to fetch state machines"
        return 1
    }
}

################################################################################
# Get state machine definition
################################################################################
get_state_machine_definition() {
    local state_machine_arn="$1"
    
    aws stepfunctions describe-state-machine \
        --state-machine-arn "${state_machine_arn}" \
        --region "${REGION}" \
        --query '[name,status,type,definition,roleArn]' \
        --output text 2>/dev/null || echo "ERROR"
}

################################################################################
# Get executions for state machine
################################################################################
get_executions() {
    local state_machine_arn="$1"
    local status_filter="${2:-ALL}"
    
    aws stepfunctions list-executions \
        --state-machine-arn "${state_machine_arn}" \
        --status-filter "${status_filter}" \
        --region "${REGION}" \
        --query 'executions[*].[executionArn,name,status,startDate,stopDate]' \
        --output text 2>/dev/null | head -50 || echo "ERROR"
}

################################################################################
# Get execution history
################################################################################
get_execution_history() {
    local execution_arn="$1"
    
    aws stepfunctions get-execution-history \
        --execution-arn "${execution_arn}" \
        --region "${REGION}" \
        --query 'events[*].[type,timestamp,id]' \
        --output text 2>/dev/null || echo "ERROR"
}

################################################################################
# Analyze state machine definition
################################################################################
analyze_state_machine_definition() {
    local state_machine_arn="$1"
    local name="$2"
    
    log_message "INFO" "Analyzing state machine: ${name}"
    
    local definition=$(aws stepfunctions describe-state-machine \
        --state-machine-arn "${state_machine_arn}" \
        --region "${REGION}" \
        --query 'definition' \
        --output text 2>/dev/null)
    
    if [[ -n "${definition}" ]]; then
        # Check for common issues in definition
        local has_retry=$(echo "${definition}" | grep -q "Retry" && echo "yes" || echo "no")
        local has_catch=$(echo "${definition}" | grep -q "Catch" && echo "yes" || echo "no")
        local state_count=$(echo "${definition}" | grep -o '"States"' | wc -l)
        
        {
            echo "  Definition Analysis:"
            echo "    Has Retry Logic: ${has_retry}"
            echo "    Has Error Handling: ${has_catch}"
            echo "    Approximate State Count: ${state_count}"
        } >> "${OUTPUT_FILE}"
    fi
}

################################################################################
# Monitor failed executions
################################################################################
monitor_failed_executions() {
    log_message "INFO" "Monitoring failed executions..."
    
    {
        echo ""
        echo "=== FAILED EXECUTIONS ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    local total_failed=0
    local sm_with_failures=0
    
    while IFS=$'\t' read -r state_machine_arn name type creation_date; do
        local failed_execs=$(get_executions "${state_machine_arn}" "FAILED")
        
        if [[ "${failed_execs}" != "ERROR" ]] && [[ -n "${failed_execs}" ]]; then
            local failed_count=$(echo "${failed_execs}" | wc -l)
            
            if [[ ${failed_count} -gt 0 ]]; then
                ((sm_with_failures++))
                total_failed=$((total_failed + failed_count))
                
                {
                    echo "State Machine: ${name}"
                    echo "  Failed Executions (Last 50): ${failed_count}"
                } >> "${OUTPUT_FILE}"
                
                if [[ ${failed_count} -ge ${FAILED_THRESHOLD} ]]; then
                    {
                        echo "  WARNING: High failure rate detected"
                    } >> "${OUTPUT_FILE}"
                fi
                
                # Show recent failures
                echo "${failed_execs}" | head -3 | while IFS=$'\t' read -r exec_arn exec_name status start_date stop_date; do
                    {
                        echo "    Recent Failure: ${exec_name}"
                        echo "      Status: ${status}"
                        echo "      Started: ${start_date}"
                    } >> "${OUTPUT_FILE}"
                done
                
                echo "" >> "${OUTPUT_FILE}"
            fi
        fi
    done < <(get_state_machines)
    
    {
        echo "Summary:"
        echo "  State Machines with Failures: ${sm_with_failures}"
        echo "  Total Failed Executions: ${total_failed}"
        echo ""
    } >> "${OUTPUT_FILE}"
    
    if [[ ${total_failed} -gt 0 ]]; then
        log_message "WARN" "Found ${total_failed} failed executions across ${sm_with_failures} state machines"
    fi
}

################################################################################
# Analyze execution duration
################################################################################
analyze_execution_duration() {
    log_message "INFO" "Analyzing execution durations..."
    
    {
        echo ""
        echo "=== EXECUTION DURATION ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r state_machine_arn name type creation_date; do
        local succeeded_execs=$(get_executions "${state_machine_arn}" "SUCCEEDED")
        
        if [[ "${succeeded_execs}" != "ERROR" ]] && [[ -n "${succeeded_execs}" ]]; then
            local total_duration=0
            local exec_count=0
            
            echo "${succeeded_execs}" | while IFS=$'\t' read -r exec_arn exec_name status start_date stop_date; do
                if [[ -n "${stop_date}" ]] && [[ -n "${start_date}" ]]; then
                    local start_ts=$(date -d "${start_date}" +%s 2>/dev/null || echo "0")
                    local stop_ts=$(date -d "${stop_date}" +%s 2>/dev/null || echo "0")
                    local duration=$((stop_ts - start_ts))
                    
                    if [[ ${duration} -gt 0 ]]; then
                        {
                            echo "  Execution: ${exec_name}"
                            echo "    Duration: ${duration}s"
                        } >> "${OUTPUT_FILE}"
                    fi
                fi
            done
            
            echo "" >> "${OUTPUT_FILE}"
        fi
    done < <(get_state_machines)
}

################################################################################
# Check state machine status
################################################################################
check_state_machine_status() {
    log_message "INFO" "Checking state machine status..."
    
    {
        echo ""
        echo "=== STATE MACHINE STATUS ==="
    } >> "${OUTPUT_FILE}"
    
    local active_count=0
    local inactive_count=0
    
    while IFS=$'\t' read -r state_machine_arn name type creation_date; do
        local sm_details=$(aws stepfunctions describe-state-machine \
            --state-machine-arn "${state_machine_arn}" \
            --region "${REGION}" \
            --query '[name,status,type]' \
            --output text 2>/dev/null)
        
        if [[ -n "${sm_details}" ]]; then
            read -r sm_name status sm_type <<< "${sm_details}"
            
            {
                echo "State Machine: ${sm_name}"
                echo "  Type: ${sm_type}"
                echo "  Status: ${status}"
                echo "  Created: ${creation_date}"
            } >> "${OUTPUT_FILE}"
            
            if [[ "${status}" == "ACTIVE" ]]; then
                ((active_count++))
            else
                ((inactive_count++))
                {
                    echo "  WARNING: State machine is not active"
                } >> "${OUTPUT_FILE}"
            fi
            
            analyze_state_machine_definition "${state_machine_arn}" "${sm_name}"
            
            echo "" >> "${OUTPUT_FILE}"
        fi
    done < <(get_state_machines)
    
    {
        echo "Status Summary:"
        echo "  Active: ${active_count}"
        echo "  Inactive: ${inactive_count}"
        echo ""
    } >> "${OUTPUT_FILE}"
}

################################################################################
# Monitor timed-out executions
################################################################################
monitor_timed_out_executions() {
    log_message "INFO" "Checking for timed-out executions..."
    
    {
        echo ""
        echo "=== TIMED-OUT EXECUTIONS ==="
    } >> "${OUTPUT_FILE}"
    
    local timeout_count=0
    
    while IFS=$'\t' read -r state_machine_arn name type creation_date; do
        # Get both FAILED and TIMED_OUT executions
        local failed_execs=$(get_executions "${state_machine_arn}" "FAILED")
        
        if [[ "${failed_execs}" != "ERROR" ]] && [[ -n "${failed_execs}" ]]; then
            echo "${failed_execs}" | while IFS=$'\t' read -r exec_arn exec_name status start_date stop_date; do
                # Get execution details to check for timeout
                local exec_details=$(aws stepfunctions describe-execution \
                    --execution-arn "${exec_arn}" \
                    --region "${REGION}" \
                    --query '[status,cause,error]' \
                    --output text 2>/dev/null || echo "")
                
                if echo "${exec_details}" | grep -q -i "timeout\|timed.out"; then
                    ((timeout_count++))
                    {
                        echo "State Machine: ${name}"
                        echo "  Execution: ${exec_name}"
                        echo "  Cause: TIMEOUT"
                        echo "  Started: ${start_date}"
                        echo ""
                    } >> "${OUTPUT_FILE}"
                fi
            done
        fi
    done < <(get_state_machines)
    
    if [[ ${timeout_count} -gt 0 ]]; then
        log_message "WARN" "Found ${timeout_count} timed-out executions"
    fi
}

################################################################################
# Analyze execution patterns
################################################################################
analyze_execution_patterns() {
    log_message "INFO" "Analyzing execution patterns..."
    
    {
        echo ""
        echo "=== EXECUTION PATTERNS ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r state_machine_arn name type creation_date; do
        # Count executions by status
        local succeeded=$(get_executions "${state_machine_arn}" "SUCCEEDED" | wc -l)
        local failed=$(get_executions "${state_machine_arn}" "FAILED" | wc -l)
        local running=$(get_executions "${state_machine_arn}" "RUNNING" | wc -l)
        local aborted=$(get_executions "${state_machine_arn}" "ABORTED" | wc -l)
        
        local total=$((succeeded + failed + running + aborted))
        
        if [[ ${total} -gt 0 ]]; then
            local success_rate=$((succeeded * 100 / total))
            local failure_rate=$((failed * 100 / total))
            
            {
                echo "State Machine: ${name}"
                echo "  Total Executions (last 50): ${total}"
                echo "  Success Rate: ${success_rate}%"
                echo "  Failure Rate: ${failure_rate}%"
                echo "  Running: ${running}"
                echo "  Aborted: ${aborted}"
            } >> "${OUTPUT_FILE}"
            
            if [[ ${failure_rate} -gt 20 ]]; then
                {
                    echo "  WARNING: High failure rate (${failure_rate}%)"
                } >> "${OUTPUT_FILE}"
            fi
            
            echo "" >> "${OUTPUT_FILE}"
        fi
    done < <(get_state_machines)
}

################################################################################
# Send Slack alert
################################################################################
send_slack_alert() {
    local sm_count="$1"
    local failed_count="$2"
    
    [[ -z "${SLACK_WEBHOOK}" ]] && return 0
    
    local payload=$(cat <<EOF
{
    "text": "AWS Step Functions Audit Report",
    "attachments": [
        {
            "color": "warning",
            "fields": [
                {"title": "Region", "value": "${REGION}", "short": true},
                {"title": "State Machines", "value": "${sm_count}", "short": true},
                {"title": "Failed Executions", "value": "${failed_count}", "short": true},
                {"title": "Analysis Period", "value": "${DAYS_BACK} days", "short": true},
                {"title": "Failure Threshold", "value": "${FAILED_THRESHOLD}", "short": true},
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
    log_message "INFO" "Starting Step Functions audit"
    
    {
        echo "AWS Step Functions Audit Report"
        echo "==============================="
        echo "Generated: $(date)"
        echo "Region: ${REGION}"
        echo "Analysis Period: ${DAYS_BACK} days"
        echo "Failed Execution Threshold: ${FAILED_THRESHOLD}"
    } > "${OUTPUT_FILE}"
    
    local sm_count=$(get_state_machines | wc -l)
    
    check_state_machine_status
    monitor_failed_executions
    monitor_timed_out_executions
    analyze_execution_duration
    analyze_execution_patterns
    
    log_message "INFO" "Audit complete. Report saved to: ${OUTPUT_FILE}"
    
    local failed_count=$(grep -c "FAILED\|TIMEOUT\|WARNING" "${OUTPUT_FILE}" || echo "0")
    
    send_slack_alert "${sm_count}" "${failed_count}"
    
    cat "${OUTPUT_FILE}"
}

main "$@"
