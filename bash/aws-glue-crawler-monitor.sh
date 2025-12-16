#!/bin/bash

################################################################################
# AWS Glue Crawler Monitor
# Monitors Glue crawlers, their execution history, and catalog metadata updates
# Detects failed crawlers, stale metadata, and crawling issues
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/glue-crawler-monitor-$(date +%s).txt"
LOG_FILE="/var/log/glue-crawler-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DAYS_BACK="${DAYS_BACK:-7}"
FAILED_THRESHOLD="${FAILED_THRESHOLD:-3}"
STALE_THRESHOLD_DAYS="${STALE_THRESHOLD_DAYS:-7}"

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
# Get all Glue crawlers
################################################################################
get_glue_crawlers() {
    aws glue get-crawlers \
        --region "${REGION}" \
        --query 'Crawlers[*].[Name,State,Role,Description,CreationTime]' \
        --output text 2>/dev/null || {
        log_message "ERROR" "Failed to fetch Glue crawlers"
        return 1
    }
}

################################################################################
# Get crawler details
################################################################################
get_crawler_details() {
    local crawler_name="$1"
    
    aws glue get-crawler \
        --name "${crawler_name}" \
        --region "${REGION}" \
        --query 'Crawler' \
        --output json 2>/dev/null || echo "ERROR"
}

################################################################################
# Get crawler runs
################################################################################
get_crawler_runs() {
    local crawler_name="$1"
    local max_results="${2:-10}"
    
    aws glue get-crawler-metrics \
        --crawler-name "${crawler_name}" \
        --region "${REGION}" \
        --query 'CrawlerMetricsList[0]' \
        --output json 2>/dev/null || echo "ERROR"
}

################################################################################
# Get crawler execution history
################################################################################
get_crawler_runs_history() {
    local crawler_name="$1"
    
    aws glue get-crawler-metrics \
        --crawler-name "${crawler_name}" \
        --region "${REGION}" \
        --query 'CrawlerMetricsList[*].[CrawlerName,LastCrawlStatus,TablesCreated,TablesUpdated,TablesDeleted]' \
        --output text 2>/dev/null | head -1
}

################################################################################
# Monitor crawler status
################################################################################
monitor_crawler_status() {
    log_message "INFO" "Monitoring Glue crawler status..."
    
    {
        echo ""
        echo "=== CRAWLER STATUS MONITOR ==="
    } >> "${OUTPUT_FILE}"
    
    local active_count=0
    local stopped_count=0
    local failed_count=0
    
    while IFS=$'\t' read -r crawler_name state role description creation_time; do
        {
            echo "Crawler: ${crawler_name}"
            echo "  Status: ${state}"
            echo "  Role: ${role}"
            echo "  Description: ${description:-N/A}"
            echo "  Created: ${creation_time}"
        } >> "${OUTPUT_FILE}"
        
        case "${state}" in
            READY)
                ((active_count++))
                ;;
            STOPPED)
                ((stopped_count++))
                ;;
            *)
                ((failed_count++))
                {
                    echo "  WARNING: Crawler state is ${state}"
                } >> "${OUTPUT_FILE}"
                ;;
        esac
        
        echo "" >> "${OUTPUT_FILE}"
    done < <(get_glue_crawlers)
    
    {
        echo "Status Summary:"
        echo "  Ready: ${active_count}"
        echo "  Stopped: ${stopped_count}"
        echo "  Other: ${failed_count}"
        echo ""
    } >> "${OUTPUT_FILE}"
}

################################################################################
# Analyze crawler metrics
################################################################################
analyze_crawler_metrics() {
    log_message "INFO" "Analyzing crawler metrics..."
    
    {
        echo ""
        echo "=== CRAWLER METRICS ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r crawler_name state role description creation_time; do
        local metrics=$(get_crawler_runs_history "${crawler_name}")
        
        if [[ "${metrics}" != "ERROR" ]] && [[ -n "${metrics}" ]]; then
            {
                echo "Crawler: ${crawler_name}"
                echo "  Metrics: ${metrics}"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_glue_crawlers)
}

################################################################################
# Check crawler schedules
################################################################################
check_crawler_schedules() {
    log_message "INFO" "Checking crawler schedules..."
    
    {
        echo ""
        echo "=== CRAWLER SCHEDULE AUDIT ==="
    } >> "${OUTPUT_FILE}"
    
    local scheduled_count=0
    local manual_count=0
    
    while IFS=$'\t' read -r crawler_name state role description creation_time; do
        local details=$(get_crawler_details "${crawler_name}")
        
        if [[ "${details}" != "ERROR" ]]; then
            local schedule=$(echo "${details}" | jq -r '.Schedule // "NONE"' 2>/dev/null || echo "NONE")
            local last_crawl=$(echo "${details}" | jq -r '.LastCrawl.EndTime // "NEVER"' 2>/dev/null || echo "NEVER")
            
            {
                echo "Crawler: ${crawler_name}"
                echo "  Schedule: ${schedule}"
                echo "  Last Crawl: ${last_crawl}"
            } >> "${OUTPUT_FILE}"
            
            if [[ "${schedule}" != "NONE" ]]; then
                ((scheduled_count++))
            else
                ((manual_count++))
            fi
            
            echo "" >> "${OUTPUT_FILE}"
        fi
    done < <(get_glue_crawlers)
    
    {
        echo "Schedule Summary:"
        echo "  Scheduled Crawlers: ${scheduled_count}"
        echo "  Manual Crawlers: ${manual_count}"
        echo ""
    } >> "${OUTPUT_FILE}"
}

################################################################################
# Monitor last crawl status
################################################################################
monitor_last_crawl_status() {
    log_message "INFO" "Monitoring last crawl status..."
    
    {
        echo ""
        echo "=== LAST CRAWL STATUS ==="
    } >> "${OUTPUT_FILE}"
    
    local successful_count=0
    local failed_crawl_count=0
    local stale_count=0
    local cutoff_date=$(date -d "${STALE_THRESHOLD_DAYS} days ago" +%s)
    
    while IFS=$'\t' read -r crawler_name state role description creation_time; do
        local details=$(get_crawler_details "${crawler_name}")
        
        if [[ "${details}" != "ERROR" ]]; then
            local last_status=$(echo "${details}" | jq -r '.LastCrawl.Status // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
            local last_end_time=$(echo "${details}" | jq -r '.LastCrawl.EndTime // "NEVER"' 2>/dev/null || echo "NEVER")
            local tables_created=$(echo "${details}" | jq -r '.LastCrawl.TablesCreated // 0' 2>/dev/null || echo "0")
            local tables_updated=$(echo "${details}" | jq -r '.LastCrawl.TablesUpdated // 0' 2>/dev/null || echo "0")
            
            {
                echo "Crawler: ${crawler_name}"
                echo "  Last Status: ${last_status}"
                echo "  Last Crawl: ${last_end_time}"
                echo "  Tables Created: ${tables_created}"
                echo "  Tables Updated: ${tables_updated}"
            } >> "${OUTPUT_FILE}"
            
            case "${last_status}" in
                SUCCEEDED)
                    ((successful_count++))
                    ;;
                FAILED|ERROR)
                    ((failed_crawl_count++))
                    {
                        echo "  WARNING: Last crawl failed"
                    } >> "${OUTPUT_FILE}"
                    ;;
            esac
            
            # Check if crawl is stale
            if [[ "${last_end_time}" != "NEVER" ]]; then
                local last_crawl_ts=$(date -d "${last_end_time}" +%s 2>/dev/null || echo "0")
                
                if [[ ${last_crawl_ts} -lt ${cutoff_date} ]]; then
                    ((stale_count++))
                    {
                        echo "  WARNING: No successful crawl in ${STALE_THRESHOLD_DAYS} days"
                    } >> "${OUTPUT_FILE}"
                fi
            fi
            
            echo "" >> "${OUTPUT_FILE}"
        fi
    done < <(get_glue_crawlers)
    
    {
        echo "Crawl Status Summary:"
        echo "  Successful: ${successful_count}"
        echo "  Failed: ${failed_crawl_count}"
        echo "  Stale: ${stale_count}"
        echo ""
    } >> "${OUTPUT_FILE}"
    
    if [[ ${failed_crawl_count} -gt 0 ]]; then
        log_message "WARN" "Found ${failed_crawl_count} crawlers with failed last crawl"
    fi
}

################################################################################
# Check crawler data sources
################################################################################
check_crawler_data_sources() {
    log_message "INFO" "Analyzing crawler data sources..."
    
    {
        echo ""
        echo "=== CRAWLER DATA SOURCES ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r crawler_name state role description creation_time; do
        local details=$(get_crawler_details "${crawler_name}")
        
        if [[ "${details}" != "ERROR" ]]; then
            local classifiers=$(echo "${details}" | jq '.Classifiers // []' 2>/dev/null)
            local targets=$(echo "${details}" | jq '.Targets // {}' 2>/dev/null)
            
            {
                echo "Crawler: ${crawler_name}"
                echo "  Classifiers: ${classifiers}"
                echo "  Targets: ${targets}"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_glue_crawlers)
}

################################################################################
# Monitor catalog updates
################################################################################
monitor_catalog_updates() {
    log_message "INFO" "Monitoring Glue catalog updates..."
    
    {
        echo ""
        echo "=== GLUE CATALOG UPDATES ==="
    } >> "${OUTPUT_FILE}"
    
    # Get catalog metadata
    local databases=$(aws glue get-databases \
        --region "${REGION}" \
        --query 'DatabaseList | length' \
        --output text 2>/dev/null || echo "0")
    
    {
        echo "Glue Catalog Summary:"
        echo "  Databases: ${databases}"
    } >> "${OUTPUT_FILE}"
    
    # Get tables across all databases
    aws glue get-databases \
        --region "${REGION}" \
        --query 'DatabaseList[*].Name' \
        --output text 2>/dev/null | while read -r db_name; do
        local table_count=$(aws glue get-tables \
            --database-name "${db_name}" \
            --region "${REGION}" \
            --query 'TableList | length' \
            --output text 2>/dev/null || echo "0")
        
        {
            echo "  Database: ${db_name} (${table_count} tables)"
        } >> "${OUTPUT_FILE}"
    done || true
    
    echo "" >> "${OUTPUT_FILE}"
}

################################################################################
# Check crawler partitions
################################################################################
check_crawler_partitions() {
    log_message "INFO" "Analyzing crawler partition updates..."
    
    {
        echo ""
        echo "=== PARTITION UPDATES ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r crawler_name state role description creation_time; do
        local details=$(get_crawler_details "${crawler_name}")
        
        if [[ "${details}" != "ERROR" ]]; then
            local partitions_created=$(echo "${details}" | jq -r '.LastCrawl.PartitionsCreated // 0' 2>/dev/null || echo "0")
            local partitions_updated=$(echo "${details}" | jq -r '.LastCrawl.PartitionsUpdated // 0' 2>/dev/null || echo "0")
            
            if [[ ${partitions_created} -gt 0 ]] || [[ ${partitions_updated} -gt 0 ]]; then
                {
                    echo "Crawler: ${crawler_name}"
                    echo "  Partitions Created: ${partitions_created}"
                    echo "  Partitions Updated: ${partitions_updated}"
                    echo ""
                } >> "${OUTPUT_FILE}"
            fi
        fi
    done < <(get_glue_crawlers)
}

################################################################################
# Send Slack alert
################################################################################
send_slack_alert() {
    local crawler_count="$1"
    local failed_count="$2"
    
    [[ -z "${SLACK_WEBHOOK}" ]] && return 0
    
    local payload=$(cat <<EOF
{
    "text": "AWS Glue Crawler Monitoring Report",
    "attachments": [
        {
            "color": "warning",
            "fields": [
                {"title": "Region", "value": "${REGION}", "short": true},
                {"title": "Crawlers", "value": "${crawler_count}", "short": true},
                {"title": "Failed", "value": "${failed_count}", "short": true},
                {"title": "Stale Threshold", "value": "${STALE_THRESHOLD_DAYS} days", "short": true},
                {"title": "Analysis Period", "value": "${DAYS_BACK} days", "short": true},
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
# Main monitoring logic
################################################################################
main() {
    log_message "INFO" "Starting Glue crawler monitoring"
    
    {
        echo "AWS Glue Crawler Monitoring Report"
        echo "==================================="
        echo "Generated: $(date)"
        echo "Region: ${REGION}"
        echo "Analysis Period: ${DAYS_BACK} days"
        echo "Stale Threshold: ${STALE_THRESHOLD_DAYS} days"
    } > "${OUTPUT_FILE}"
    
    local crawler_count=$(get_glue_crawlers | wc -l)
    
    monitor_crawler_status
    analyze_crawler_metrics
    check_crawler_schedules
    monitor_last_crawl_status
    check_crawler_data_sources
    monitor_catalog_updates
    check_crawler_partitions
    
    log_message "INFO" "Monitoring complete. Report saved to: ${OUTPUT_FILE}"
    
    local failed_count=$(grep -c "FAILED\|WARNING" "${OUTPUT_FILE}" || echo "0")
    
    send_slack_alert "${crawler_count}" "${failed_count}"
    
    cat "${OUTPUT_FILE}"
}

main "$@"
