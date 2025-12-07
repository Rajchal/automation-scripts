#!/bin/bash

################################################################################
# AWS Glue Job Monitor
# Monitors AWS Glue jobs, reports failures, and triggers notifications
# Useful for tracking ETL pipeline health and job performance
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
DAYS_BACK="${DAYS_BACK:-1}"
FAILED_THRESHOLD="${FAILED_THRESHOLD:-5}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL="${EMAIL:-}"
LOG_FILE="/var/log/aws-glue-monitor.log"
OUTPUT_FILE="/tmp/glue-job-report-$(date +%s).txt"

################################################################################
# Logging
################################################################################
log_message() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

################################################################################
# Get all Glue jobs
################################################################################
get_all_glue_jobs() {
    log_message "INFO" "Fetching all Glue jobs from region: ${REGION}"
    aws glue get-jobs \
        --region "${REGION}" \
        --query 'Jobs[*].Name' \
        --output text 2>/dev/null || {
        log_message "ERROR" "Failed to fetch Glue jobs"
        return 1
    }
}

################################################################################
# Get job run history
################################################################################
get_job_runs() {
    local job_name="$1"
    local limit="${2:-10}"
    
    aws glue get-job-runs \
        --job-name "${job_name}" \
        --region "${REGION}" \
        --max-items "${limit}" \
        --query 'JobRuns[*].[Id,State,StartTime,EndTime,ErrorMessage]' \
        --output text 2>/dev/null
}

################################################################################
# Analyze job health
################################################################################
analyze_job_health() {
    local job_name="$1"
    local failed_count=0
    local success_count=0
    local timeout_count=0
    
    log_message "INFO" "Analyzing job: ${job_name}"
    
    while IFS=$'\t' read -r job_id state start_time end_time error_msg; do
        case "${state}" in
            FAILED)
                ((failed_count++))
                echo "  [FAILED] Run ID: ${job_id}" >> "${OUTPUT_FILE}"
                [[ -n "${error_msg}" ]] && echo "    Error: ${error_msg}" >> "${OUTPUT_FILE}"
                ;;
            SUCCEEDED)
                ((success_count++))
                ;;
            TIMEOUT)
                ((timeout_count++))
                echo "  [TIMEOUT] Run ID: ${job_id}" >> "${OUTPUT_FILE}"
                ;;
        esac
    done < <(get_job_runs "${job_name}")
    
    echo "  Summary - Success: ${success_count}, Failed: ${failed_count}, Timeout: ${timeout_count}" >> "${OUTPUT_FILE}"
    
    if [[ ${failed_count} -ge ${FAILED_THRESHOLD} ]]; then
        return 0  # Alert needed
    fi
    
    return 1
}

################################################################################
# Get job metrics
################################################################################
get_job_metrics() {
    local job_name="$1"
    
    # Try to get CloudWatch metrics for the job
    aws cloudwatch get-metric-statistics \
        --namespace "AWS/Glue" \
        --metric-name "glue.driver.aggregate.numFailedTasks" \
        --dimensions Name=JobName,Value="${job_name}" \
        --start-time "$(date -u -d "${DAYS_BACK} days ago" +%Y-%m-%dT%H:%M:%S)" \
        --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
        --period 3600 \
        --statistics Sum \
        --region "${REGION}" \
        --query 'Datapoints[*].[Timestamp,Sum]' \
        --output text 2>/dev/null || echo "N/A"
}

################################################################################
# Send Slack notification
################################################################################
send_slack_alert() {
    local job_name="$1"
    local message="$2"
    
    [[ -z "${SLACK_WEBHOOK}" ]] && return 0
    
    local payload=$(cat <<EOF
{
    "text": "AWS Glue Job Alert",
    "attachments": [
        {
            "color": "danger",
            "fields": [
                {"title": "Job Name", "value": "${job_name}", "short": true},
                {"title": "Region", "value": "${REGION}", "short": true},
                {"title": "Alert", "value": "${message}", "short": false},
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
# Send email alert
################################################################################
send_email_alert() {
    local subject="$1"
    local body_file="$2"
    
    [[ -z "${EMAIL}" ]] && return 0
    [[ ! -f "${body_file}" ]] && return 1
    
    mail -s "${subject}" "${EMAIL}" < "${body_file}" 2>/dev/null || {
        log_message "WARN" "Failed to send email alert"
        return 1
    }
}

################################################################################
# Main monitoring logic
################################################################################
main() {
    log_message "INFO" "Starting AWS Glue job monitoring"
    
    {
        echo "AWS Glue Job Monitoring Report"
        echo "=============================="
        echo "Generated: $(date)"
        echo "Region: ${REGION}"
        echo ""
    } > "${OUTPUT_FILE}"
    
    local jobs_to_alert=()
    
    while IFS= read -r job_name; do
        if analyze_job_health "${job_name}"; then
            jobs_to_alert+=("${job_name}")
        fi
    done < <(get_all_glue_jobs)
    
    if [[ ${#jobs_to_alert[@]} -gt 0 ]]; then
        log_message "WARN" "Found ${#jobs_to_alert[@]} jobs exceeding failure threshold"
        
        echo "" >> "${OUTPUT_FILE}"
        echo "Jobs Requiring Attention:" >> "${OUTPUT_FILE}"
        for job in "${jobs_to_alert[@]}"; do
            echo "  - ${job}" >> "${OUTPUT_FILE}"
            send_slack_alert "${job}" "Job has exceeded ${FAILED_THRESHOLD} failures in recent runs"
        done
        
        send_email_alert "AWS Glue Job Failures Alert" "${OUTPUT_FILE}"
    else
        log_message "INFO" "All Glue jobs are healthy"
    fi
    
    log_message "INFO" "Report saved to: ${OUTPUT_FILE}"
}

main "$@"
