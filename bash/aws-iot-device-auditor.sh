#!/bin/bash

################################################################################
# AWS IoT Device Auditor
# Audits IoT devices, certificates, and connectivity status
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
CERT_EXPIRY_DAYS="${CERT_EXPIRY_DAYS:-30}"
OUTPUT_FILE="/tmp/iot-device-audit-$(date +%s).txt"
LOG_FILE="/var/log/iot-device-audit.log"
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
# Get all IoT devices (things)
################################################################################
get_iot_things() {
    aws iot list-things \
        --region "${REGION}" \
        --query 'things[*].[thingName,thingArn,thingTypeName,attributes]' \
        --output text 2>/dev/null || {
        log_message "ERROR" "Failed to fetch IoT things"
        return 1
    }
}

################################################################################
# Get device certificates
################################################################################
get_device_certificates() {
    local thing_name="$1"
    
    aws iot list-thing-principals \
        --thing-name "${thing_name}" \
        --region "${REGION}" \
        --query 'principals[*]' \
        --output text 2>/dev/null || echo "ERROR"
}

################################################################################
# Get certificate details
################################################################################
get_certificate_details() {
    local cert_arn="$1"
    
    # Extract certificate ID from ARN
    local cert_id=$(echo "${cert_arn}" | awk -F'/' '{print $NF}')
    
    aws iot describe-certificate \
        --certificate-id "${cert_id}" \
        --region "${REGION}" \
        --query 'certificateDescription.[certificateId,status,creationDate,lastModifiedDate,certificatePem]' \
        --output text 2>/dev/null || echo "ERROR"
}

################################################################################
# Check certificate expiry
################################################################################
get_certificate_expiry() {
    local cert_pem="$1"
    
    echo "${cert_pem}" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "UNKNOWN"
}

################################################################################
# Get device connectivity status
################################################################################
get_device_connectivity() {
    local thing_name="$1"
    
    # Check shadow document for connectivity status
    aws iot-data get-thing-shadow \
        --thing-name "${thing_name}" \
        --region "${REGION}" \
        --output text 2>/dev/null | jq '.state.reported.connected' || echo "UNKNOWN"
}

################################################################################
# Audit device connectivity
################################################################################
audit_device_connectivity() {
    log_message "INFO" "Auditing device connectivity status..."
    
    {
        echo ""
        echo "=== DEVICE CONNECTIVITY STATUS ==="
    } >> "${OUTPUT_FILE}"
    
    local connected_count=0
    local disconnected_count=0
    
    while IFS=$'\t' read -r thing_name thing_arn thing_type attributes; do
        local status=$(get_device_connectivity "${thing_name}" || echo "UNKNOWN")
        
        if [[ "${status}" == "true" ]]; then
            ((connected_count++))
        else
            ((disconnected_count++))
            {
                echo "Device: ${thing_name}"
                echo "  Status: DISCONNECTED/UNKNOWN"
                echo "  Thing ARN: ${thing_arn}"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_iot_things)
    
    {
        echo "Connected Devices: ${connected_count}"
        echo "Disconnected/Unknown Devices: ${disconnected_count}"
        echo ""
    } >> "${OUTPUT_FILE}"
    
    if [[ ${disconnected_count} -gt 0 ]]; then
        log_message "WARN" "Found ${disconnected_count} devices with connectivity issues"
    fi
}

################################################################################
# Audit certificate expiry
################################################################################
audit_certificate_expiry() {
    log_message "INFO" "Checking certificate expiry dates..."
    
    {
        echo ""
        echo "=== CERTIFICATE EXPIRY AUDIT ==="
    } >> "${OUTPUT_FILE}"
    
    local expiring_count=0
    local expired_count=0
    local cutoff_date=$(date -d "+${CERT_EXPIRY_DAYS} days" +%s)
    local now=$(date +%s)
    
    while IFS=$'\t' read -r thing_name thing_arn thing_type attributes; do
        local certs=$(get_device_certificates "${thing_name}")
        
        if [[ "${certs}" != "ERROR" ]]; then
            for cert_arn in ${certs}; do
                local cert_details=$(get_certificate_details "${cert_arn}")
                
                if [[ "${cert_details}" != "ERROR" ]]; then
                    # Extract expiry date from certificate
                    local cert_id=$(echo "${cert_arn}" | awk -F'/' '{print $NF}')
                    local cert_pem=$(aws iot describe-certificate \
                        --certificate-id "${cert_id}" \
                        --region "${REGION}" \
                        --query 'certificateDescription.certificatePem' \
                        --output text 2>/dev/null)
                    
                    local expiry_date=$(get_certificate_expiry "${cert_pem}")
                    local expiry_timestamp=$(date -d "${expiry_date}" +%s 2>/dev/null || echo "0")
                    
                    if [[ ${expiry_timestamp} -le ${now} ]]; then
                        ((expired_count++))
                        {
                            echo "Device: ${thing_name}"
                            echo "  Certificate ID: ${cert_id}"
                            echo "  Status: EXPIRED"
                            echo "  Expiry Date: ${expiry_date}"
                            echo ""
                        } >> "${OUTPUT_FILE}"
                    elif [[ ${expiry_timestamp} -le ${cutoff_date} ]]; then
                        ((expiring_count++))
                        {
                            echo "Device: ${thing_name}"
                            echo "  Certificate ID: ${cert_id}"
                            echo "  Status: EXPIRING SOON"
                            echo "  Expiry Date: ${expiry_date}"
                            echo ""
                        } >> "${OUTPUT_FILE}"
                    fi
                fi
            done
        fi
    done < <(get_iot_things)
    
    {
        echo "Expired Certificates: ${expired_count}"
        echo "Expiring Soon (${CERT_EXPIRY_DAYS} days): ${expiring_count}"
        echo ""
    } >> "${OUTPUT_FILE}"
    
    if [[ $((expired_count + expiring_count)) -gt 0 ]]; then
        log_message "WARN" "Found $((expired_count + expiring_count)) certificates with expiry issues"
    fi
}

################################################################################
# Audit inactive devices
################################################################################
audit_inactive_devices() {
    log_message "INFO" "Analyzing device activity..."
    
    {
        echo ""
        echo "=== INACTIVE DEVICES ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    local inactive_count=0
    
    while IFS=$'\t' read -r thing_name thing_arn thing_type attributes; do
        # This is a simplified check - actual activity tracking would use CloudWatch metrics
        {
            echo "Device: ${thing_name}"
            echo "  Thing Type: ${thing_type:-Not Specified}"
            echo "  ARN: ${thing_arn}"
            echo ""
        } >> "${OUTPUT_FILE}"
    done < <(get_iot_things)
    
    log_message "INFO" "Device listing complete"
}

################################################################################
# Audit device policies
################################################################################
audit_device_policies() {
    log_message "INFO" "Auditing device policies..."
    
    {
        echo ""
        echo "=== DEVICE POLICIES ==="
    } >> "${OUTPUT_FILE}"
    
    # List all IoT policies
    local policies=$(aws iot list-policies \
        --region "${REGION}" \
        --query 'policies[*].policyName' \
        --output text 2>/dev/null || echo "ERROR")
    
    if [[ "${policies}" != "ERROR" ]]; then
        {
            echo "Found Policies:"
            for policy in ${policies}; do
                echo "  - ${policy}"
            done
            echo ""
        } >> "${OUTPUT_FILE}"
    fi
}

################################################################################
# Audit thing groups
################################################################################
audit_thing_groups() {
    log_message "INFO" "Auditing thing groups..."
    
    {
        echo ""
        echo "=== THING GROUPS ==="
    } >> "${OUTPUT_FILE}"
    
    aws iot list-thing-groups \
        --region "${REGION}" \
        --query 'thingGroups[*].[groupName,groupArn]' \
        --output text 2>/dev/null | while IFS=$'\t' read -r group_name group_arn; do
        {
            echo "Group: ${group_name}"
            echo "  ARN: ${group_arn}"
            echo ""
        } >> "${OUTPUT_FILE}"
    done || log_message "WARN" "Failed to fetch thing groups"
}

################################################################################
# Send Slack notification
################################################################################
send_slack_alert() {
    local device_count="$1"
    local issues="$2"
    
    [[ -z "${SLACK_WEBHOOK}" ]] && return 0
    
    local payload=$(cat <<EOF
{
    "text": "AWS IoT Device Audit",
    "attachments": [
        {
            "color": "warning",
            "fields": [
                {"title": "Region", "value": "${REGION}", "short": true},
                {"title": "Total Devices", "value": "${device_count}", "short": true},
                {"title": "Issues Found", "value": "${issues}", "short": true},
                {"title": "Cert Expiry Check", "value": "${CERT_EXPIRY_DAYS} days", "short": true},
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
    log_message "INFO" "Starting AWS IoT device audit"
    
    {
        echo "AWS IoT Device Audit Report"
        echo "============================"
        echo "Generated: $(date)"
        echo "Region: ${REGION}"
        echo "Certificate Expiry Check Window: ${CERT_EXPIRY_DAYS} days"
    } > "${OUTPUT_FILE}"
    
    local device_count=$(get_iot_things 2>/dev/null | wc -l || echo "0")
    
    audit_device_connectivity
    audit_certificate_expiry
    audit_inactive_devices
    audit_device_policies
    audit_thing_groups
    
    log_message "INFO" "Audit complete. Report saved to: ${OUTPUT_FILE}"
    
    # Count issues
    local issue_count=$(grep -c "DISCONNECTED\|EXPIRED\|EXPIRING" "${OUTPUT_FILE}" || echo "0")
    
    send_slack_alert "${device_count}" "${issue_count}"
    
    cat "${OUTPUT_FILE}"
}

main "$@"
