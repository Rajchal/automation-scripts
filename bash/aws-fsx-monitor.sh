#!/bin/bash

################################################################################
# AWS FSx File Systems Monitor
# Monitors FSx file systems (Windows, Lustre, OpenZFS, NetApp ONTAP)
# Detects storage capacity issues, backups, and performance problems
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/fsx-monitor-$(date +%s).txt"
LOG_FILE="/var/log/fsx-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
STORAGE_THRESHOLD="${STORAGE_THRESHOLD:-80}"  # % capacity warning
DAYS_BACK="${DAYS_BACK:-7}"

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
# Get all FSx file systems
################################################################################
get_fsx_file_systems() {
    aws fsx describe-file-systems \
        --region "${REGION}" \
        --query 'FileSystems[*].[FileSystemId,FileSystemType,Lifecycle,CreationTime,StorageCapacity]' \
        --output text 2>/dev/null || {
        log_message "ERROR" "Failed to fetch FSx file systems"
        return 1
    }
}

################################################################################
# Get file system details
################################################################################
get_file_system_details() {
    local fs_id="$1"
    
    aws fsx describe-file-systems \
        --file-system-ids "${fs_id}" \
        --region "${REGION}" \
        --query 'FileSystems[0]' \
        --output json 2>/dev/null || echo "ERROR"
}

################################################################################
# Get storage usage metrics
################################################################################
get_storage_usage() {
    local fs_id="$1"
    local metric_name="$2"
    
    aws cloudwatch get-metric-statistics \
        --namespace "AWS/FSx" \
        --metric-name "${metric_name}" \
        --dimensions Name=FileSystemId,Value="${fs_id}" \
        --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)" \
        --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
        --period 300 \
        --statistics Average,Maximum \
        --region "${REGION}" \
        --query 'Datapoints[0].Average' \
        --output text 2>/dev/null || echo "N/A"
}

################################################################################
# Get backups for file system
################################################################################
get_file_system_backups() {
    local fs_id="$1"
    
    aws fsx describe-backups \
        --region "${REGION}" \
        --filters "Name=file-system-id,Values=${fs_id}" \
        --query 'Backups[*].[BackupId,Status,CreationTime,Type]' \
        --output text 2>/dev/null | head -10 || echo "ERROR"
}

################################################################################
# Monitor file system health
################################################################################
monitor_file_system_health() {
    log_message "INFO" "Monitoring FSx file system health..."
    
    {
        echo ""
        echo "=== FILE SYSTEM HEALTH STATUS ==="
    } >> "${OUTPUT_FILE}"
    
    local healthy_count=0
    local unhealthy_count=0
    
    while IFS=$'\t' read -r fs_id fs_type lifecycle creation_time storage_capacity; do
        {
            echo "File System: ${fs_id}"
            echo "  Type: ${fs_type}"
            echo "  Status: ${lifecycle}"
            echo "  Storage Capacity: ${storage_capacity} GB"
            echo "  Created: ${creation_time}"
        } >> "${OUTPUT_FILE}"
        
        if [[ "${lifecycle}" == "AVAILABLE" ]]; then
            ((healthy_count++))
        else
            ((unhealthy_count++))
            {
                echo "  WARNING: File system is ${lifecycle}"
            } >> "${OUTPUT_FILE}"
        fi
        
        echo "" >> "${OUTPUT_FILE}"
    done < <(get_fsx_file_systems)
    
    {
        echo "Health Summary:"
        echo "  Available: ${healthy_count}"
        echo "  Unhealthy: ${unhealthy_count}"
        echo ""
    } >> "${OUTPUT_FILE}"
    
    if [[ ${unhealthy_count} -gt 0 ]]; then
        log_message "WARN" "Found ${unhealthy_count} unhealthy file systems"
    fi
}

################################################################################
# Monitor storage capacity
################################################################################
monitor_storage_capacity() {
    log_message "INFO" "Monitoring storage capacity..."
    
    {
        echo ""
        echo "=== STORAGE CAPACITY ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    local near_capacity_count=0
    
    while IFS=$'\t' read -r fs_id fs_type lifecycle creation_time storage_capacity; do
        if [[ "${lifecycle}" == "AVAILABLE" ]]; then
            # Get used storage
            local used_storage=$(get_storage_usage "${fs_id}" "UsedStorageCapacity")
            
            if [[ "${used_storage}" != "N/A" ]]; then
                local capacity_bytes=$((storage_capacity * 1024 * 1024 * 1024))
                local used_bytes=$(printf "%.0f" "${used_storage}" 2>/dev/null || echo "0")
                local used_percent=$((used_bytes * 100 / capacity_bytes))
                
                {
                    echo "File System: ${fs_id} (${fs_type})"
                    echo "  Total Capacity: ${storage_capacity} GB"
                    echo "  Used: ${used_bytes} bytes (${used_percent}%)"
                } >> "${OUTPUT_FILE}"
                
                if [[ ${used_percent} -ge ${STORAGE_THRESHOLD} ]]; then
                    ((near_capacity_count++))
                    {
                        echo "  WARNING: Storage usage above ${STORAGE_THRESHOLD}% threshold"
                    } >> "${OUTPUT_FILE}"
                fi
                
                echo "" >> "${OUTPUT_FILE}"
            fi
        fi
    done < <(get_fsx_file_systems)
    
    if [[ ${near_capacity_count} -gt 0 ]]; then
        log_message "WARN" "Found ${near_capacity_count} file systems near capacity"
    fi
}

################################################################################
# Monitor throughput performance
################################################################################
monitor_throughput_performance() {
    log_message "INFO" "Analyzing throughput performance..."
    
    {
        echo ""
        echo "=== THROUGHPUT PERFORMANCE ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r fs_id fs_type lifecycle creation_time storage_capacity; do
        if [[ "${lifecycle}" == "AVAILABLE" ]]; then
            local read_throughput=$(get_storage_usage "${fs_id}" "DataReadOperations")
            local write_throughput=$(get_storage_usage "${fs_id}" "DataWriteOperations")
            
            {
                echo "File System: ${fs_id} (${fs_type})"
                echo "  Read Operations: ${read_throughput}"
                echo "  Write Operations: ${write_throughput}"
            } >> "${OUTPUT_FILE}"
            
            echo "" >> "${OUTPUT_FILE}"
        fi
    done < <(get_fsx_file_systems)
}

################################################################################
# Audit backup configuration
################################################################################
audit_backup_configuration() {
    log_message "INFO" "Auditing backup configurations..."
    
    {
        echo ""
        echo "=== BACKUP CONFIGURATION AUDIT ==="
    } >> "${OUTPUT_FILE}"
    
    local missing_backups=0
    local stale_backups=0
    local cutoff_date=$(date -d "${DAYS_BACK} days ago" +%s)
    
    while IFS=$'\t' read -r fs_id fs_type lifecycle creation_time storage_capacity; do
        local backups=$(get_file_system_backups "${fs_id}")
        
        {
            echo "File System: ${fs_id} (${fs_type})"
        } >> "${OUTPUT_FILE}"
        
        if [[ "${backups}" == "ERROR" ]] || [[ -z "${backups}" ]]; then
            ((missing_backups++))
            {
                echo "  WARNING: No backups found"
            } >> "${OUTPUT_FILE}"
        else
            local backup_count=$(echo "${backups}" | wc -l)
            local latest_backup=$(echo "${backups}" | head -1 | awk '{print $3}')
            
            {
                echo "  Backup Count: ${backup_count}"
                echo "  Latest Backup: ${latest_backup}"
            } >> "${OUTPUT_FILE}"
            
            if [[ -n "${latest_backup}" ]]; then
                local backup_ts=$(date -d "${latest_backup}" +%s 2>/dev/null || echo "0")
                
                if [[ ${backup_ts} -lt ${cutoff_date} ]]; then
                    ((stale_backups++))
                    {
                        echo "  WARNING: Latest backup is older than ${DAYS_BACK} days"
                    } >> "${OUTPUT_FILE}"
                fi
            fi
        fi
        
        echo "" >> "${OUTPUT_FILE}"
    done < <(get_fsx_file_systems)
    
    if [[ ${missing_backups} -gt 0 ]]; then
        log_message "WARN" "Found ${missing_backups} file systems without backups"
    fi
    
    if [[ ${stale_backups} -gt 0 ]]; then
        log_message "WARN" "Found ${stale_backups} file systems with stale backups"
    fi
}

################################################################################
# Monitor Windows-specific metrics
################################################################################
monitor_windows_specific() {
    log_message "INFO" "Monitoring Windows FSx specific metrics..."
    
    {
        echo ""
        echo "=== WINDOWS FSx SPECIFIC METRICS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r fs_id fs_type lifecycle creation_time storage_capacity; do
        if [[ "${fs_type}" == "WINDOWS" ]]; then
            local details=$(get_file_system_details "${fs_id}")
            
            if [[ "${details}" != "ERROR" ]]; then
                local multi_az=$(echo "${details}" | jq -r '.WindowsConfiguration.MultiAZ' 2>/dev/null || echo "N/A")
                local throughput=$(echo "${details}" | jq -r '.WindowsConfiguration.ThroughputCapacity' 2>/dev/null || echo "N/A")
                local dns=$(echo "${details}" | jq -r '.DNSName' 2>/dev/null || echo "N/A")
                
                {
                    echo "Windows File System: ${fs_id}"
                    echo "  Multi-AZ: ${multi_az}"
                    echo "  Throughput Capacity: ${throughput} MB/s"
                    echo "  DNS Name: ${dns}"
                    echo ""
                } >> "${OUTPUT_FILE}"
            fi
        fi
    done < <(get_fsx_file_systems)
}

################################################################################
# Monitor Lustre-specific metrics
################################################################################
monitor_lustre_specific() {
    log_message "INFO" "Monitoring Lustre FSx specific metrics..."
    
    {
        echo ""
        echo "=== LUSTRE FSx SPECIFIC METRICS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r fs_id fs_type lifecycle creation_time storage_capacity; do
        if [[ "${fs_type}" == "LUSTRE" ]]; then
            local details=$(get_file_system_details "${fs_id}")
            
            if [[ "${details}" != "ERROR" ]]; then
                local deployment=$(echo "${details}" | jq -r '.LustreConfiguration.DeploymentType' 2>/dev/null || echo "N/A")
                local per_unit=$(echo "${details}" | jq -r '.LustreConfiguration.PerUnitStorageThroughput' 2>/dev/null || echo "N/A")
                
                {
                    echo "Lustre File System: ${fs_id}"
                    echo "  Deployment Type: ${deployment}"
                    echo "  Per Unit Storage Throughput: ${per_unit} MB/s/TiB"
                    echo ""
                } >> "${OUTPUT_FILE}"
            fi
        fi
    done < <(get_fsx_file_systems)
}

################################################################################
# Check for maintenance events
################################################################################
check_maintenance_events() {
    log_message "INFO" "Checking for maintenance events..."
    
    {
        echo ""
        echo "=== MAINTENANCE EVENTS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r fs_id fs_type lifecycle creation_time storage_capacity; do
        local details=$(get_file_system_details "${fs_id}")
        
        if [[ "${details}" != "ERROR" ]]; then
            local maintenance=$(echo "${details}" | jq -r '.AdministrativeActions[] | select(.AdministrativeActionType=="FILE_SYSTEM_UPDATE" or .AdministrativeActionType=="STORAGE_OPTIMIZATION")' 2>/dev/null)
            
            if [[ -n "${maintenance}" ]]; then
                {
                    echo "File System: ${fs_id}"
                    echo "  Pending Administrative Actions:"
                    echo "${maintenance}" | jq -r '.AdministrativeActionType' | while read -r action; do
                        echo "    - ${action}"
                    done
                    echo ""
                } >> "${OUTPUT_FILE}"
            fi
        fi
    done < <(get_fsx_file_systems)
}

################################################################################
# Send Slack alert
################################################################################
send_slack_alert() {
    local fs_count="$1"
    local issues="$2"
    
    [[ -z "${SLACK_WEBHOOK}" ]] && return 0
    
    local payload=$(cat <<EOF
{
    "text": "AWS FSx File Systems Monitoring Report",
    "attachments": [
        {
            "color": "warning",
            "fields": [
                {"title": "Region", "value": "${REGION}", "short": true},
                {"title": "File Systems", "value": "${fs_count}", "short": true},
                {"title": "Issues Found", "value": "${issues}", "short": true},
                {"title": "Storage Threshold", "value": "${STORAGE_THRESHOLD}%", "short": true},
                {"title": "Backup Check Period", "value": "${DAYS_BACK} days", "short": true},
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
    log_message "INFO" "Starting FSx file systems monitoring"
    
    {
        echo "AWS FSx File Systems Monitoring Report"
        echo "======================================"
        echo "Generated: $(date)"
        echo "Region: ${REGION}"
        echo "Storage Capacity Threshold: ${STORAGE_THRESHOLD}%"
        echo "Backup Analysis Period: ${DAYS_BACK} days"
    } > "${OUTPUT_FILE}"
    
    local fs_count=$(get_fsx_file_systems | wc -l)
    
    monitor_file_system_health
    monitor_storage_capacity
    monitor_throughput_performance
    audit_backup_configuration
    monitor_windows_specific
    monitor_lustre_specific
    check_maintenance_events
    
    log_message "INFO" "Monitoring complete. Report saved to: ${OUTPUT_FILE}"
    
    local issue_count=$(grep -c "WARNING" "${OUTPUT_FILE}" || echo "0")
    
    send_slack_alert "${fs_count}" "${issue_count}"
    
    cat "${OUTPUT_FILE}"
}

main "$@"
