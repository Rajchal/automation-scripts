#!/bin/bash

################################################################################
# AWS Redshift Cluster Auditor
# Audits Redshift clusters for performance, configuration, and cost optimization
# Detects idle clusters, underutilized nodes, and security issues
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/redshift-audit-$(date +%s).txt"
LOG_FILE="/var/log/redshift-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
IDLE_THRESHOLD="${IDLE_THRESHOLD:-5}"  # CPU utilization % for idle detection
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
# Get all Redshift clusters
################################################################################
get_redshift_clusters() {
    aws redshift describe-clusters \
        --region "${REGION}" \
        --query 'Clusters[*].[ClusterIdentifier,NodeType,NumberOfNodes,ClusterStatus,ClusterCreateTime,Endpoint.Address]' \
        --output text 2>/dev/null || {
        log_message "ERROR" "Failed to fetch Redshift clusters"
        return 1
    }
}

################################################################################
# Get cluster details
################################################################################
get_cluster_details() {
    local cluster_id="$1"
    
    aws redshift describe-clusters \
        --cluster-identifier "${cluster_id}" \
        --region "${REGION}" \
        --query 'Clusters[0]' \
        --output json 2>/dev/null || echo "ERROR"
}

################################################################################
# Get cluster performance metrics
################################################################################
get_cluster_metrics() {
    local cluster_id="$1"
    local metric_name="$2"
    local stat="${3:-Average}"
    
    aws cloudwatch get-metric-statistics \
        --namespace "AWS/Redshift" \
        --metric-name "${metric_name}" \
        --dimensions Name=ClusterIdentifier,Value="${cluster_id}" \
        --start-time "$(date -u -d "${DAYS_BACK} days ago" +%Y-%m-%dT%H:%M:%S)" \
        --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
        --period 3600 \
        --statistics "${stat}" \
        --region "${REGION}" \
        --query "Datapoints[*].${stat}" \
        --output text 2>/dev/null | awk '{s+=$1} END {print s/NR}' || echo "N/A"
}

################################################################################
# Audit cluster health
################################################################################
audit_cluster_health() {
    log_message "INFO" "Auditing cluster health..."
    
    {
        echo ""
        echo "=== CLUSTER HEALTH STATUS ==="
    } >> "${OUTPUT_FILE}"
    
    local unhealthy_count=0
    
    while IFS=$'\t' read -r cluster_id node_type node_count status create_time endpoint; do
        {
            echo "Cluster: ${cluster_id}"
            echo "  Status: ${status}"
            echo "  Node Type: ${node_type}"
            echo "  Node Count: ${node_count}"
            echo "  Created: ${create_time}"
            echo "  Endpoint: ${endpoint}"
        } >> "${OUTPUT_FILE}"
        
        if [[ "${status}" != "available" ]]; then
            {
                echo "  WARNING: Cluster is ${status}"
            } >> "${OUTPUT_FILE}"
            ((unhealthy_count++))
        fi
        
        echo "" >> "${OUTPUT_FILE}"
    done < <(get_redshift_clusters)
    
    if [[ ${unhealthy_count} -gt 0 ]]; then
        log_message "WARN" "Found ${unhealthy_count} clusters with non-available status"
    fi
}

################################################################################
# Audit idle clusters
################################################################################
audit_idle_clusters() {
    log_message "INFO" "Detecting idle clusters (CPU < ${IDLE_THRESHOLD}%)..."
    
    {
        echo ""
        echo "=== IDLE CLUSTER DETECTION ==="
    } >> "${OUTPUT_FILE}"
    
    local idle_count=0
    
    while IFS=$'\t' read -r cluster_id node_type node_count status _ _; do
        if [[ "${status}" == "available" ]]; then
            local cpu_util=$(get_cluster_metrics "${cluster_id}" "CPUUtilization" "Average")
            
            # Check if CPU is low
            if [[ "${cpu_util}" != "N/A" ]]; then
                local cpu_int=$(printf "%.0f" "${cpu_util}" 2>/dev/null || echo "0")
                
                {
                    echo "Cluster: ${cluster_id}"
                    echo "  Average CPU Utilization (${DAYS_BACK}d): ${cpu_int}%"
                } >> "${OUTPUT_FILE}"
                
                if [[ ${cpu_int} -lt ${IDLE_THRESHOLD} ]]; then
                    {
                        echo "  STATUS: IDLE - Candidate for downsizing or termination"
                    } >> "${OUTPUT_FILE}"
                    ((idle_count++))
                fi
                
                echo "" >> "${OUTPUT_FILE}"
            fi
        fi
    done < <(get_redshift_clusters)
    
    if [[ ${idle_count} -gt 0 ]]; then
        log_message "WARN" "Found ${idle_count} idle clusters"
    fi
}

################################################################################
# Audit query performance
################################################################################
audit_query_performance() {
    log_message "INFO" "Analyzing query performance metrics..."
    
    {
        echo ""
        echo "=== QUERY PERFORMANCE ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r cluster_id node_type node_count status _ _; do
        if [[ "${status}" == "available" ]]; then
            local query_duration=$(get_cluster_metrics "${cluster_id}" "QueryDuration" "Average")
            local read_throughput=$(get_cluster_metrics "${cluster_id}" "ReadThroughput" "Average")
            local write_throughput=$(get_cluster_metrics "${cluster_id}" "WriteThroughput" "Average")
            
            {
                echo "Cluster: ${cluster_id}"
                echo "  Avg Query Duration: ${query_duration}ms"
                echo "  Read Throughput: ${read_throughput} bytes/s"
                echo "  Write Throughput: ${write_throughput} bytes/s"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_redshift_clusters)
}

################################################################################
# Audit security groups
################################################################################
audit_security_groups() {
    log_message "INFO" "Auditing security group configurations..."
    
    {
        echo ""
        echo "=== SECURITY GROUP AUDIT ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r cluster_id node_type node_count status _ _; do
        if [[ "${status}" == "available" ]]; then
            local details=$(get_cluster_details "${cluster_id}")
            
            if [[ "${details}" != "ERROR" ]]; then
                local sg_ids=$(echo "${details}" | jq -r '.VpcSecurityGroups[*].VpcSecurityGroupId' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
                local publicly_accessible=$(echo "${details}" | jq -r '.PubliclyAccessible' 2>/dev/null || echo "false")
                
                {
                    echo "Cluster: ${cluster_id}"
                    echo "  Security Groups: ${sg_ids}"
                    echo "  Publicly Accessible: ${publicly_accessible}"
                } >> "${OUTPUT_FILE}"
                
                if [[ "${publicly_accessible}" == "true" ]]; then
                    {
                        echo "  WARNING: Cluster is publicly accessible"
                    } >> "${OUTPUT_FILE}"
                fi
                
                echo "" >> "${OUTPUT_FILE}"
            fi
        fi
    done < <(get_redshift_clusters)
}

################################################################################
# Audit parameter groups
################################################################################
audit_parameter_groups() {
    log_message "INFO" "Auditing parameter group configurations..."
    
    {
        echo ""
        echo "=== PARAMETER GROUP AUDIT ==="
    } >> "${OUTPUT_FILE}"
    
    aws redshift describe-cluster-parameter-groups \
        --region "${REGION}" \
        --query 'ParameterGroups[*].[ParameterGroupName,Description]' \
        --output text 2>/dev/null | while IFS=$'\t' read -r param_group_name description; do
        {
            echo "Parameter Group: ${param_group_name}"
            echo "  Description: ${description:-N/A}"
            echo ""
        } >> "${OUTPUT_FILE}"
    done || log_message "WARN" "Failed to fetch parameter groups"
}

################################################################################
# Audit maintenance windows
################################################################################
audit_maintenance_windows() {
    log_message "INFO" "Checking maintenance window configurations..."
    
    {
        echo ""
        echo "=== MAINTENANCE WINDOW AUDIT ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r cluster_id node_type node_count status _ _; do
        local details=$(get_cluster_details "${cluster_id}")
        
        if [[ "${details}" != "ERROR" ]]; then
            local preferred_maint_window=$(echo "${details}" | jq -r '.PreferredMaintenanceWindow' 2>/dev/null || echo "N/A")
            
            {
                echo "Cluster: ${cluster_id}"
                echo "  Preferred Maintenance Window: ${preferred_maint_window}"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_redshift_clusters)
}

################################################################################
# Audit backup settings
################################################################################
audit_backup_settings() {
    log_message "INFO" "Auditing backup configurations..."
    
    {
        echo ""
        echo "=== BACKUP CONFIGURATION AUDIT ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r cluster_id node_type node_count status _ _; do
        local details=$(get_cluster_details "${cluster_id}")
        
        if [[ "${details}" != "ERROR" ]]; then
            local automated_backup=$(echo "${details}" | jq -r '.AutomatedSnapshotRetentionPeriod' 2>/dev/null || echo "0")
            local backup_enabled=$(echo "${details}" | jq -r '.EnhancedVpcRouting' 2>/dev/null || echo "false")
            
            {
                echo "Cluster: ${cluster_id}"
                echo "  Automated Snapshot Retention: ${automated_backup} days"
                echo "  Enhanced VPC Routing: ${backup_enabled}"
            } >> "${OUTPUT_FILE}"
            
            if [[ "${automated_backup}" == "0" ]]; then
                {
                    echo "  WARNING: Automated snapshots are disabled"
                } >> "${OUTPUT_FILE}"
            fi
            
            echo "" >> "${OUTPUT_FILE}"
        fi
    done < <(get_redshift_clusters)
}

################################################################################
# Calculate cost optimization
################################################################################
calculate_cost_optimization() {
    log_message "INFO" "Calculating cost optimization opportunities..."
    
    {
        echo ""
        echo "=== COST OPTIMIZATION RECOMMENDATIONS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r cluster_id node_type node_count status _ _; do
        if [[ "${status}" == "available" ]]; then
            local cpu_util=$(get_cluster_metrics "${cluster_id}" "CPUUtilization" "Average")
            
            if [[ "${cpu_util}" != "N/A" ]]; then
                local cpu_int=$(printf "%.0f" "${cpu_util}" 2>/dev/null || echo "0")
                
                {
                    echo "Cluster: ${cluster_id}"
                    echo "  Node Type: ${node_type}"
                    echo "  Node Count: ${node_count}"
                    echo "  CPU Utilization: ${cpu_int}%"
                } >> "${OUTPUT_FILE}"
                
                if [[ ${cpu_int} -lt 20 ]]; then
                    {
                        echo "  RECOMMENDATION: Consider reducing node count or using smaller node type"
                    } >> "${OUTPUT_FILE}"
                elif [[ ${cpu_int} -gt 85 ]]; then
                    {
                        echo "  RECOMMENDATION: Consider increasing node count or scaling up"
                    } >> "${OUTPUT_FILE}"
                fi
                
                echo "" >> "${OUTPUT_FILE}"
            fi
        fi
    done < <(get_redshift_clusters)
}

################################################################################
# Send Slack alert
################################################################################
send_slack_alert() {
    local cluster_count="$1"
    local issues="$2"
    
    [[ -z "${SLACK_WEBHOOK}" ]] && return 0
    
    local payload=$(cat <<EOF
{
    "text": "AWS Redshift Cluster Audit",
    "attachments": [
        {
            "color": "warning",
            "fields": [
                {"title": "Region", "value": "${REGION}", "short": true},
                {"title": "Clusters Audited", "value": "${cluster_count}", "short": true},
                {"title": "Issues Found", "value": "${issues}", "short": true},
                {"title": "Idle Threshold", "value": "${IDLE_THRESHOLD}%", "short": true},
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
# Main audit logic
################################################################################
main() {
    log_message "INFO" "Starting Redshift cluster audit"
    
    {
        echo "AWS Redshift Cluster Audit Report"
        echo "=================================="
        echo "Generated: $(date)"
        echo "Region: ${REGION}"
        echo "Analysis Period: ${DAYS_BACK} days"
        echo "Idle Threshold: ${IDLE_THRESHOLD}%"
    } > "${OUTPUT_FILE}"
    
    local cluster_count=$(get_redshift_clusters | wc -l)
    
    audit_cluster_health
    audit_idle_clusters
    audit_query_performance
    audit_security_groups
    audit_parameter_groups
    audit_maintenance_windows
    audit_backup_settings
    calculate_cost_optimization
    
    log_message "INFO" "Audit complete. Report saved to: ${OUTPUT_FILE}"
    
    local issue_count=$(grep -c "WARNING\|RECOMMENDATION" "${OUTPUT_FILE}" || echo "0")
    
    send_slack_alert "${cluster_count}" "${issue_count}"
    
    cat "${OUTPUT_FILE}"
}

main "$@"
