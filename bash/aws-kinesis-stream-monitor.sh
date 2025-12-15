#!/bin/bash

################################################################################
# AWS Kinesis Stream Monitor
# Monitors Kinesis streams, shards, throughput, and iterator age
# Detects bottlenecks, hot shards, and performance issues
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/kinesis-stream-monitor-$(date +%s).txt"
LOG_FILE="/var/log/kinesis-stream-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
ALERT_THRESHOLD_ITERATOR_AGE="${ALERT_THRESHOLD_ITERATOR_AGE:-3600}"  # 1 hour in seconds
ALERT_THRESHOLD_THROUGHPUT="${ALERT_THRESHOLD_THROUGHPUT:-80}"  # 80% utilization

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
# Get all Kinesis streams
################################################################################
get_kinesis_streams() {
    aws kinesis list-streams \
        --region "${REGION}" \
        --query 'StreamNames[]' \
        --output text 2>/dev/null || {
        log_message "ERROR" "Failed to fetch Kinesis streams"
        return 1
    }
}

################################################################################
# Get stream description
################################################################################
get_stream_description() {
    local stream_name="$1"
    
    aws kinesis describe-stream \
        --stream-name "${stream_name}" \
        --region "${REGION}" \
        --query 'StreamDescription' \
        --output json 2>/dev/null || echo "ERROR"
}

################################################################################
# Get shard metrics
################################################################################
get_shard_metrics() {
    local stream_name="$1"
    local shard_id="$2"
    local metric_name="$3"
    
    aws cloudwatch get-metric-statistics \
        --namespace "AWS/Kinesis" \
        --metric-name "${metric_name}" \
        --dimensions Name=StreamName,Value="${stream_name}" Name=ShardID,Value="${shard_id}" \
        --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)" \
        --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
        --period 300 \
        --statistics Sum,Average,Maximum \
        --region "${REGION}" \
        --query 'Datapoints[*].[Timestamp,Maximum,Sum]' \
        --output text 2>/dev/null || echo "N/A"
}

################################################################################
# Monitor stream health
################################################################################
monitor_stream_health() {
    local stream_name="$1"
    
    log_message "INFO" "Monitoring stream: ${stream_name}"
    
    local description=$(get_stream_description "${stream_name}")
    
    if [[ "${description}" == "ERROR" ]]; then
        log_message "ERROR" "Could not describe stream: ${stream_name}"
        return 1
    fi
    
    local stream_status=$(echo "${description}" | jq -r '.StreamStatus')
    local shard_count=$(echo "${description}" | jq '.Shards | length')
    local creation_timestamp=$(echo "${description}" | jq -r '.StreamCreationTimestamp')
    
    {
        echo "Stream: ${stream_name}"
        echo "  Status: ${stream_status}"
        echo "  Shard Count: ${shard_count}"
        echo "  Created: ${creation_timestamp}"
    } >> "${OUTPUT_FILE}"
    
    # Check for DELETING or FAILED status
    if [[ "${stream_status}" != "ACTIVE" ]]; then
        {
            echo "  WARNING: Stream is ${stream_status}"
        } >> "${OUTPUT_FILE}"
        log_message "WARN" "Stream ${stream_name} is ${stream_status}"
    fi
    
    echo "" >> "${OUTPUT_FILE}"
}

################################################################################
# Analyze shard distribution
################################################################################
analyze_shard_distribution() {
    local stream_name="$1"
    
    log_message "INFO" "Analyzing shard distribution for: ${stream_name}"
    
    local description=$(get_stream_description "${stream_name}")
    
    if [[ "${description}" == "ERROR" ]]; then
        return 1
    fi
    
    {
        echo "=== SHARD ANALYSIS: ${stream_name} ==="
    } >> "${OUTPUT_FILE}"
    
    local shard_index=0
    
    echo "${description}" | jq -c '.Shards[]' | while read -r shard_data; do
        local shard_id=$(echo "${shard_data}" | jq -r '.ShardId')
        local key_range=$(echo "${shard_data}" | jq -r '.HashKeyRange')
        local seq_range=$(echo "${shard_data}" | jq -r '.SequenceNumberRange')
        
        {
            echo "  Shard: ${shard_id}"
            echo "    Key Range: ${key_range}"
            echo "    Sequence Range: ${seq_range}"
        } >> "${OUTPUT_FILE}"
        
        ((shard_index++))
    done
    
    echo "" >> "${OUTPUT_FILE}"
}

################################################################################
# Check iterator age
################################################################################
check_iterator_age() {
    local stream_name="$1"
    
    log_message "INFO" "Checking iterator age for: ${stream_name}"
    
    {
        echo "=== ITERATOR AGE CHECK: ${stream_name} ==="
    } >> "${OUTPUT_FILE}"
    
    local description=$(get_stream_description "${stream_name}")
    
    if [[ "${description}" == "ERROR" ]]; then
        return 1
    fi
    
    local old_iterator_count=0
    
    echo "${description}" | jq -c '.Shards[]' | while read -r shard_data; do
        local shard_id=$(echo "${shard_data}" | jq -r '.ShardId')
        
        local iterator_age=$(get_shard_metrics "${stream_name}" "${shard_id}" "GetRecords.IteratorAgeMilliseconds")
        
        if [[ "${iterator_age}" != "N/A" ]]; then
            local iterator_seconds=$((iterator_age / 1000))
            
            {
                echo "  Shard ${shard_id}:"
                echo "    Iterator Age: ${iterator_seconds}s"
            } >> "${OUTPUT_FILE}"
            
            if [[ ${iterator_seconds} -gt ${ALERT_THRESHOLD_ITERATOR_AGE} ]]; then
                {
                    echo "    WARNING: Iterator age exceeds threshold (${ALERT_THRESHOLD_ITERATOR_AGE}s)"
                } >> "${OUTPUT_FILE}"
                ((old_iterator_count++))
            fi
        fi
    done
    
    if [[ ${old_iterator_count} -gt 0 ]]; then
        log_message "WARN" "Found ${old_iterator_count} shards with old iterators in ${stream_name}"
    fi
    
    echo "" >> "${OUTPUT_FILE}"
}

################################################################################
# Monitor throughput
################################################################################
monitor_throughput() {
    local stream_name="$1"
    
    log_message "INFO" "Monitoring throughput for: ${stream_name}"
    
    {
        echo "=== THROUGHPUT ANALYSIS: ${stream_name} ==="
    } >> "${OUTPUT_FILE}"
    
    local description=$(get_stream_description "${stream_name}")
    
    if [[ "${description}" == "ERROR" ]]; then
        return 1
    fi
    
    echo "${description}" | jq -c '.StreamModeDetails' | while read -r mode_data; do
        local stream_mode=$(echo "${mode_data}" | jq -r '.StreamMode // "PROVISIONED"')
        
        {
            echo "  Stream Mode: ${stream_mode}"
        } >> "${OUTPUT_FILE}"
        
        if [[ "${stream_mode}" == "PROVISIONED" ]]; then
            echo "${description}" | jq -c '.Shards[]' | while read -r shard_data; do
                local shard_id=$(echo "${shard_data}" | jq -r '.ShardId')
                
                # Get IncomingRecords metric
                local incoming=$(get_shard_metrics "${stream_name}" "${shard_id}" "IncomingRecords")
                local outgoing=$(get_shard_metrics "${stream_name}" "${shard_id}" "OutgoingRecords")
                
                {
                    echo "  Shard ${shard_id}:"
                    echo "    Incoming Records: ${incoming}"
                    echo "    Outgoing Records: ${outgoing}"
                } >> "${OUTPUT_FILE}"
            done
        fi
    done
    
    echo "" >> "${OUTPUT_FILE}"
}

################################################################################
# Monitor for late arrivals
################################################################################
monitor_late_arrivals() {
    local stream_name="$1"
    
    log_message "INFO" "Checking for late-arriving records in: ${stream_name}"
    
    {
        echo "=== LATE ARRIVALS CHECK: ${stream_name} ==="
    } >> "${OUTPUT_FILE}"
    
    local description=$(get_stream_description "${stream_name}")
    
    if [[ "${description}" == "ERROR" ]]; then
        return 1
    fi
    
    echo "${description}" | jq -c '.Shards[]' | while read -r shard_data; do
        local shard_id=$(echo "${shard_data}" | jq -r '.ShardId')
        
        # Check GetRecords.LatencyMs for late data
        local latency=$(get_shard_metrics "${stream_name}" "${shard_id}" "GetRecords.LatencyMicros")
        
        if [[ "${latency}" != "N/A" ]]; then
            {
                echo "  Shard ${shard_id}:"
                echo "    Latency: ${latency}µs"
            } >> "${OUTPUT_FILE}"
        fi
    done
    
    echo "" >> "${OUTPUT_FILE}"
}

################################################################################
# Check consumer lag
################################################################################
check_consumer_lag() {
    local stream_name="$1"
    
    log_message "INFO" "Checking consumer lag for: ${stream_name}"
    
    {
        echo "=== CONSUMER LAG CHECK: ${stream_name} ==="
    } >> "${OUTPUT_FILE}"
    
    # List consumers for this stream
    local consumers=$(aws kinesis list-stream-consumers \
        --stream-arn "arn:aws:kinesis:${REGION}:$(aws sts get-caller-identity --query Account --output text):stream/${stream_name}" \
        --region "${REGION}" \
        --query 'Consumers[*].[ConsumerName,ConsumerARN]' \
        --output text 2>/dev/null || echo "NONE")
    
    if [[ "${consumers}" == "NONE" ]] || [[ -z "${consumers}" ]]; then
        {
            echo "  No consumers registered for this stream"
        } >> "${OUTPUT_FILE}"
    else
        {
            echo "  Found consumers:"
            echo "${consumers}" | while IFS=$'\t' read -r consumer_name consumer_arn; do
                echo "    - ${consumer_name}"
            done
        } >> "${OUTPUT_FILE}"
    fi
    
    echo "" >> "${OUTPUT_FILE}"
}

################################################################################
# Send Slack alert
################################################################################
send_slack_alert() {
    local stream_count="$1"
    local issues="$2"
    
    [[ -z "${SLACK_WEBHOOK}" ]] && return 0
    
    local payload=$(cat <<EOF
{
    "text": "AWS Kinesis Stream Monitoring Report",
    "attachments": [
        {
            "color": "warning",
            "fields": [
                {"title": "Region", "value": "${REGION}", "short": true},
                {"title": "Streams Monitored", "value": "${stream_count}", "short": true},
                {"title": "Issues Found", "value": "${issues}", "short": true},
                {"title": "Iterator Age Threshold", "value": "${ALERT_THRESHOLD_ITERATOR_AGE}s", "short": true},
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
    log_message "INFO" "Starting Kinesis stream monitoring"
    
    {
        echo "AWS Kinesis Stream Monitoring Report"
        echo "====================================="
        echo "Generated: $(date)"
        echo "Region: ${REGION}"
        echo "Iterator Age Threshold: ${ALERT_THRESHOLD_ITERATOR_AGE}s"
        echo ""
    } > "${OUTPUT_FILE}"
    
    local stream_count=0
    local issue_count=0
    
    while IFS= read -r stream_name; do
        ((stream_count++))
        
        monitor_stream_health "${stream_name}"
        analyze_shard_distribution "${stream_name}"
        check_iterator_age "${stream_name}"
        monitor_throughput "${stream_name}"
        monitor_late_arrivals "${stream_name}"
        check_consumer_lag "${stream_name}"
        
    done < <(get_kinesis_streams)
    
    log_message "INFO" "Monitoring complete. Report saved to: ${OUTPUT_FILE}"
    
    issue_count=$(grep -c "WARNING" "${OUTPUT_FILE}" || echo "0")
    
    send_slack_alert "${stream_count}" "${issue_count}"
    
    cat "${OUTPUT_FILE}"
}

main "$@"
