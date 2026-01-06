#!/bin/bash

################################################################################
# AWS Backup Auditor
# Audits AWS Backup vaults, backup plans, and recovery points for retention,
# encryption, and orphaned recovery points
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/aws-backup-audit-$(date +%s).txt"
LOG_FILE="/var/log/aws-backup-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
RECENT_DAYS_WARN="${RECENT_DAYS_WARN:-30}"

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

# API wrappers
list_backup_vaults() {
  aws backup list-backup-vaults --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_backup_plans() {
  aws backup list-backup-plans --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_recovery_points_by_vault() {
  local vault_name="$1"
  aws backup list-recovery-points-by-backup-vault --backup-vault-name "${vault_name}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_backup_plan() {
  local plan_id="$1"
  aws backup get-backup-plan --backup-plan-id "${plan_id}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_recovery_point_restore_metadata() {
  local vault_name="$1"; local recovery_point_arn="$2"
  aws backup get-recovery-point-restore-metadata --backup-vault-name "${vault_name}" --recovery-point-arn "${recovery_point_arn}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS Backup Audit Report"
    echo "========================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Recent Days Warn: ${RECENT_DAYS_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_backup_vaults() {
  log_message INFO "Auditing backup vaults"
  {
    echo "=== BACKUP VAULTS ==="
  } >> "${OUTPUT_FILE}"

  local vaults
  vaults=$(list_backup_vaults)

  local total_vaults=0 total_recovery_points=0 old_recovery_points=0 encrypted_count=0 unencrypted=0 orphaned=0

  echo "${vaults}" | jq -c '.BackupVaultList[]?' 2>/dev/null | while read -r vault; do
    ((total_vaults++))
    local vault_name vault_arn
    vault_name=$(echo "${vault}" | jq_safe '.BackupVaultName')
    vault_arn=$(echo "${vault}" | jq_safe '.BackupVaultArn')

    {
      echo "Vault: ${vault_name}"
      echo "  ARN: ${vault_arn}"
    } >> "${OUTPUT_FILE}"

    # Recovery points
    local rps
    rps=$(list_recovery_points_by_vault "${vault_name}")
    local rp_count
    rp_count=$(echo "${rps}" | jq '.RecoveryPoints | length' 2>/dev/null || echo 0)
    ((total_recovery_points+=rp_count))

    if (( rp_count == 0 )); then
      echo "  WARNING: No recovery points in vault" >> "${OUTPUT_FILE}"
    fi

    echo "  Recovery Points: ${rp_count}" >> "${OUTPUT_FILE}"

    echo "${rps}" | jq -c '.RecoveryPoints[]?' 2>/dev/null | while read -r rp; do
      local rp_arn resource_type created cp
      rp_arn=$(echo "${rp}" | jq_safe '.RecoveryPointArn')
      resource_type=$(echo "${rp}" | jq_safe '.ResourceType')
      created=$(echo "${rp}" | jq_safe '.CreationDate')
      cp=$(echo "${rp}" | jq_safe '.CalculatedLifecycle')

      # Age
      local age_days=0
      if [[ -n "${created}" && "${created}" != "null" ]]; then
        local created_epoch now_epoch
        created_epoch=$(date -d "${created}" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        age_days=$(( (now_epoch - created_epoch) / 86400 ))
      fi

      echo "    Recovery Point: ${rp_arn}" >> "${OUTPUT_FILE}"
      echo "      ResourceType: ${resource_type}" >> "${OUTPUT_FILE}"
      echo "      Created: ${created} (${age_days} days)" >> "${OUTPUT_FILE}"

      if (( age_days >= RECENT_DAYS_WARN )); then
        ((old_recovery_points++))
        echo "      WARNING: Recovery point older than ${RECENT_DAYS_WARN} days" >> "${OUTPUT_FILE}"
      fi

      # Check encryption
      local encrypted
      encrypted=$(echo "${rp}" | jq_safe '.Encrypted')
      if [[ "${encrypted}" == "true" ]]; then
        ((encrypted_count++))
      else
        ((unencrypted++))
        echo "      WARNING: Recovery point not encrypted" >> "${OUTPUT_FILE}"
      fi

      # Check restore metadata for references
      local meta
      meta=$(get_recovery_point_restore_metadata "${vault_name}" "${rp_arn}")
      if [[ -z "${meta}" || "${meta}" == "{}" ]]; then
        ((orphaned++))
        echo "      INFO: No restore metadata found (possibly orphaned)" >> "${OUTPUT_FILE}"
      fi

      echo "" >> "${OUTPUT_FILE}"
    done

  done

  {
    echo "Backup Vault Summary:"
    echo "  Total Vaults: ${total_vaults}"
    echo "  Total Recovery Points: ${total_recovery_points}"
    echo "  Old Recovery Points (>= ${RECENT_DAYS_WARN}d): ${old_recovery_points}"
    echo "  Encrypted Recovery Points: ${encrypted_count}"
    echo "  Unencrypted Recovery Points: ${unencrypted}"
    echo "  Potentially Orphaned Recovery Points: ${orphaned}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_backup_plans() {
  log_message INFO "Auditing backup plans"
  {
    echo "=== BACKUP PLANS ==="
  } >> "${OUTPUT_FILE}"

  local plans
  plans=$(list_backup_plans)

  local total_plans=0 plans_without_rules=0 backup_vaults_missing=0

  echo "${plans}" | jq -c '.BackupPlansList[]?' 2>/dev/null | while read -r plan; do
    ((total_plans++))
    local plan_id plan_name
    plan_id=$(echo "${plan}" | jq_safe '.BackupPlanId')
    plan_name=$(echo "${plan}" | jq_safe '.BackupPlanName')

    {
      echo "Plan: ${plan_name}"
      echo "  ID: ${plan_id}"
    } >> "${OUTPUT_FILE}"

    local plan_details
    plan_details=$(get_backup_plan "${plan_id}")
    local rules_count
    rules_count=$(echo "${plan_details}" | jq '.BackupPlan.Rules | length' 2>/dev/null || echo 0)

    if (( rules_count == 0 )); then
      ((plans_without_rules++))
      echo "  WARNING: Backup plan has no rules" >> "${OUTPUT_FILE}"
    else
      echo "  Rules: ${rules_count}" >> "${OUTPUT_FILE}"
    fi

    # Check that each rule references an existing vault
    echo "${plan_details}" | jq -c '.BackupPlan.Rules[]?' 2>/dev/null | while read -r rule; do
      local target_vault
      target_vault=$(echo "${rule}" | jq_safe '.TargetBackupVaultName')
      if [[ -z "${target_vault}" || "${target_vault}" == "null" ]]; then
        ((backup_vaults_missing++))
        echo "  WARNING: Rule missing target vault" >> "${OUTPUT_FILE}"
      fi
    done

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Backup Plans Summary:"
    echo "  Total Plans: ${total_plans}"
    echo "  Plans Without Rules: ${plans_without_rules}"
    echo "  Rules Missing Vaults: ${backup_vaults_missing}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total_vaults="$1"; local old_rps="$2"; local unencrypted="$3"; local orphaned="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  (( unencrypted > 0 || orphaned > 0 )) && color="danger"
  (( old_rps > 0 && color == "good" )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Backup Audit Report",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Total Vaults", "value": "${total_vaults}", "short": true},
        {"title": "Old Recovery Points", "value": "${old_rps}", "short": true},
        {"title": "Unencrypted", "value": "${unencrypted}", "short": true},
        {"title": "Potential Orphaned", "value": "${orphaned}", "short": true},
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Timestamp", "value": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "short": false}
      ]
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

main() {
  log_message INFO "Starting AWS Backup audit"
  write_header
  audit_backup_vaults
  audit_backup_plans
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total_vaults old_rps unencrypted orphaned
  total_vaults=$(grep "Total Vaults:" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  old_rps=$(grep "Old Recovery Points" -n "${OUTPUT_FILE}" | awk -F: '{print $2}' | awk '{print $NF}' 2>/dev/null || true)
  if [[ -z "${old_rps}" ]]; then old_rps=0; fi
  unencrypted=$(grep "Unencrypted Recovery Points" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  orphaned=$(grep "Potentially Orphaned Recovery Points" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  send_slack_alert "${total_vaults}" "${old_rps}" "${unencrypted}" "${orphaned}"
  cat "${OUTPUT_FILE}"
}

main "$@"
