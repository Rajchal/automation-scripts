#!/bin/bash

################################################################################
# AWS Backup Vault Auditor
# Audits backup vaults, recovery points, and backup compliance
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
MIN_RECOVERY_POINTS="${MIN_RECOVERY_POINTS:-3}"
OUTPUT_FILE="/tmp/backup-vault-audit-$(date +%s).txt"
LOG_FILE="/var/log/backup-vault-audit.log"
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
# Get all backup vaults
################################################################################
get_backup_vaults() {
    aws backup list-backup-vaults \
        --region "${REGION}" \
        --query 'BackupVaultList[*].[BackupVaultName,BackupVaultArn,CreationTime,NumberOfRecoveryPoints]' \
        --output text 2>/dev/null || {
        log_message "ERROR" "Failed to fetch backup vaults"
        return 1
    }
}

################################################################################
# Get recovery points for vault
################################################################################
get_recovery_points() {
    local vault_name="$1"
    
    aws backup list-recovery-points-by-backup-vault \
        --backup-vault-name "${vault_name}" \
        --region "${REGION}" \
        --query 'RecoveryPoints[*].[RecoveryPointArn,Status,CreationTime,CompletionDate,ResourceType]' \
        --output text 2>/dev/null || echo "ERROR"
}

################################################################################
# Get backup plan information
################################################################################
get_backup_plans() {
    aws backup list-backup-plans \
        --region "${REGION}" \
        --query 'BackupPlansList[*].[BackupPlanName,BackupPlanId,CreationDate,LastUpdatedDate]' \
        --output text 2>/dev/null || echo "ERROR"
}

################################################################################
# Audit recovery points per vault
################################################################################
audit_recovery_points() {
    log_message "INFO" "Auditing recovery points in vaults..."
    
    {
        echo ""
        echo "=== RECOVERY POINTS ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    local low_recovery_count=0
    
    while IFS=$'\t' read -r vault_name vault_arn creation_time recovery_count; do
        local completed_count=0
        local failed_count=0
        local partial_count=0
        
        while IFS=$'\t' read -r recovery_arn status created_time completion_date resource_type; do
            case "${status}" in
                COMPLETED)
                    ((completed_count++))
                    ;;
                FAILED)
                    ((failed_count++))
                    ;;
                PARTIAL)
                    ((partial_count++))
                    ;;
            esac
        done < <(get_recovery_points "${vault_name}")
        
        {
            echo "Vault: ${vault_name}"
            echo "  Completed Recovery Points: ${completed_count}"
            echo "  Failed Recovery Points: ${failed_count}"
            echo "  Partial Recovery Points: ${partial_count}"
        } >> "${OUTPUT_FILE}"
        
        if [[ ${completed_count} -lt ${MIN_RECOVERY_POINTS} ]]; then
            ((low_recovery_count++))
            echo "  WARNING: Below minimum recovery points (${MIN_RECOVERY_POINTS})" >> "${OUTPUT_FILE}"
        fi
        
        echo "" >> "${OUTPUT_FILE}"
    done < <(get_backup_vaults)
    
    if [[ ${low_recovery_count} -gt 0 ]]; then
        log_message "WARN" "Found ${low_recovery_count} vaults with insufficient recovery points"
    fi
}

################################################################################
# Audit failed backups
################################################################################
audit_failed_backups() {
    log_message "INFO" "Checking for failed backups..."
    
    {
        echo ""
        echo "=== FAILED BACKUPS ==="
    } >> "${OUTPUT_FILE}"
    
    local total_failed=0
    
    while IFS=$'\t' read -r vault_name vault_arn _ _; do
        while IFS=$'\t' read -r recovery_arn status created_time completion_date resource_type; do
            if [[ "${status}" == "FAILED" ]]; then
                ((total_failed++))
                {
                    echo "Vault: ${vault_name}"
                    echo "  Recovery Point: ${recovery_arn}"
                    echo "  Resource Type: ${resource_type}"
                    echo "  Created: ${created_time}"
                    echo ""
                } >> "${OUTPUT_FILE}"
            fi
        done < <(get_recovery_points "${vault_name}")
    done < <(get_backup_vaults)
    
    if [[ ${total_failed} -gt 0 ]]; then
        log_message "WARN" "Found ${total_failed} failed backup recovery points"
    fi
}

################################################################################
# Audit vault access policies
################################################################################
audit_vault_policies() {
    log_message "INFO" "Auditing backup vault access policies..."
    
    {
        echo ""
        echo "=== VAULT ACCESS POLICIES ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r vault_name vault_arn _ _; do
        local policy=$(aws backup get-backup-vault-access-policy \
            --backup-vault-name "${vault_name}" \
            --region "${REGION}" \
            --query 'Policy' \
            --output text 2>/dev/null || echo "No Policy")
        
        if [[ "${policy}" != "No Policy" ]] && [[ -n "${policy}" ]]; then
            {
                echo "Vault: ${vault_name}"
                echo "  Has Access Policy: Yes"
                echo ""
            } >> "${OUTPUT_FILE}"
        else
            {
                echo "Vault: ${vault_name}"
                echo "  Has Access Policy: No (default private)"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_backup_vaults)
}

################################################################################
# Audit backup plans
################################################################################
audit_backup_plans() {
    log_message "INFO" "Auditing backup plans..."
    
    {
        echo ""
        echo "=== BACKUP PLANS STATUS ==="
    } >> "${OUTPUT_FILE}"
    
    local plan_count=0
    
    while IFS=$'\t' read -r plan_name plan_id creation_date update_date; do
        ((plan_count++))
        {
            echo "Plan: ${plan_name}"
            echo "  Plan ID: ${plan_id}"
            echo "  Created: ${creation_date}"
            echo "  Last Updated: ${update_date}"
            echo ""
        } >> "${OUTPUT_FILE}"
    done < <(get_backup_plans)
    
    log_message "INFO" "Found ${plan_count} backup plans"
}

################################################################################
# Audit retention settings
################################################################################
audit_retention_settings() {
    log_message "INFO" "Analyzing retention settings..."
    
    {
        echo ""
        echo "=== RETENTION ANALYSIS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r vault_name vault_arn creation_time recovery_count; do
        local oldest_point=""
        local newest_point=""
        
        while IFS=$'\t' read -r recovery_arn status created_time completion_date resource_type; do
            if [[ "${status}" == "COMPLETED" ]]; then
                if [[ -z "${oldest_point}" ]]; then
                    oldest_point="${created_time}"
                fi
                newest_point="${created_time}"
            fi
        done < <(get_recovery_points "${vault_name}")
        
        if [[ -n "${oldest_point}" ]]; then
            {
                echo "Vault: ${vault_name}"
                echo "  Oldest Recovery Point: ${oldest_point}"
                echo "  Newest Recovery Point: ${newest_point}"
                echo ""
            } >> "${OUTPUT_FILE}"
        fi
    done < <(get_backup_vaults)
}

################################################################################
# Send Slack notification
################################################################################
send_slack_alert() {
    local vault_count="$1"
    local failed_count="$2"
    
    [[ -z "${SLACK_WEBHOOK}" ]] && return 0
    
    local payload=$(cat <<EOF
{
    "text": "AWS Backup Vault Audit",
    "attachments": [
        {
            "color": "warning",
            "fields": [
                {"title": "Region", "value": "${REGION}", "short": true},
                {"title": "Vaults Audited", "value": "${vault_count}", "short": true},
                {"title": "Failed Backups", "value": "${failed_count}", "short": true},
                {"title": "Min Recovery Points", "value": "${MIN_RECOVERY_POINTS}", "short": true},
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
    log_message "INFO" "Starting AWS Backup vault audit"
    
    {
        echo "AWS Backup Vault Audit Report"
        echo "============================="
        echo "Generated: $(date)"
        echo "Region: ${REGION}"
        echo "Minimum Recovery Points: ${MIN_RECOVERY_POINTS}"
    } > "${OUTPUT_FILE}"
    
    # Count vaults
    local vault_count=$(get_backup_vaults | wc -l)
    
    audit_recovery_points
    audit_failed_backups
    audit_vault_policies
    audit_backup_plans
    audit_retention_settings
    
    log_message "INFO" "Audit complete. Report saved to: ${OUTPUT_FILE}"
    
    # Count failed backups
    local failed_count=$(grep -c "FAILED" "${OUTPUT_FILE}" || echo "0")
    
    send_slack_alert "${vault_count}" "${failed_count}"
    
    cat "${OUTPUT_FILE}"
}

main "$@"
