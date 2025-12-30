#!/bin/bash

################################################################################
# AWS Backup Compliance Auditor
# Audits AWS Backup: vault configs/encryption, backup plans/assignments,
# last success timestamps per resource, cross-region copy settings, backup
# drift. CloudWatch metrics: BackupJobsCreated, BackupJobsFailed,
# BackupJobsCompleted, RestoreJobsCreated, RestoreJobsFailed.
# Includes logging, Slack/email alerts, and compliance report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/backup-compliance-audit-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/backup-compliance-audit.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds
FAILED_JOBS_WARN="${FAILED_JOBS_WARN:-5}"
DAYS_SINCE_SUCCESS_WARN="${DAYS_SINCE_SUCCESS_WARN:-3}"
VAULT_ENCRYPTION_REQUIRED="${VAULT_ENCRYPTION_REQUIRED:-true}"
CROSS_REGION_COPY_REQUIRED="${CROSS_REGION_COPY_REQUIRED:-false}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-3600}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_VAULTS=0
UNENCRYPTED_VAULTS=0
TOTAL_BACKUP_PLANS=0
PLANS_WITH_ISSUES=0
TOTAL_BACKUP_JOBS=0
FAILED_BACKUP_JOBS=0
STALE_BACKUPS=0
RESOURCES_NO_BACKUP=0

ISSUES=()

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || echo ""; }

aws_cmd() {
  if [[ -n "${PROFILE}" ]]; then AWS_PROFILE="${PROFILE}" aws "$@"; else aws "$@"; fi
}

send_slack_alert() {
  local message="$1"
  local severity="${2:-INFO}"
  [[ -z "${SLACK_WEBHOOK}" ]] && return
  local color
  case "${severity}" in
    CRITICAL) color="danger" ;;
    WARNING)  color="warning" ;;
    INFO)     color="good" ;;
    *)        color="good" ;;
  esac
  local payload
  payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "${color}",
      "title": "AWS Backup Compliance Alert",
      "text": "${message}",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || true
}

send_email_alert() {
  local subject="$1"
  local body="$2"
  [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null && return
  echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true
}

write_header() {
  {
    echo "AWS Backup Compliance Audit"
    echo "==========================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Compliance Requirements:"
    echo "  Failed Jobs Warning Threshold: > ${FAILED_JOBS_WARN}"
    echo "  Stale Backup Warning: > ${DAYS_SINCE_SUCCESS_WARN} days"
    echo "  Vault Encryption Required: ${VAULT_ENCRYPTION_REQUIRED}"
    echo "  Cross-Region Copy Required: ${CROSS_REGION_COPY_REQUIRED}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_backup_vaults() {
  aws_cmd backup list-backup-vaults \
    --output json 2>/dev/null || echo '{"BackupVaultList":[]}'
}

describe_backup_vault() {
  local vault_name="$1"
  aws_cmd backup describe-backup-vault \
    --backup-vault-name "${vault_name}" \
    --output json 2>/dev/null || echo '{}'
}

list_backup_plans() {
  aws_cmd backup list-backup-plans \
    --output json 2>/dev/null || echo '{"BackupPlansList":[]}'
}

get_backup_plan() {
  local plan_id="$1"
  aws_cmd backup get-backup-plan \
    --backup-plan-id "${plan_id}" \
    --output json 2>/dev/null || echo '{"BackupPlan":{}}'
}

list_backup_plan_resources() {
  local plan_id="$1"
  aws_cmd backup list-backup-plan-resources \
    --backup-plan-id "${plan_id}" \
    --output json 2>/dev/null || echo '{"Resources":[]}'
}

list_recovery_points() {
  local vault_name="$1"
  aws_cmd backup list-recovery-points-by-backup-vault \
    --backup-vault-name "${vault_name}" \
    --output json 2>/dev/null || echo '{"RecoveryPoints":[]}'
}

list_backup_jobs() {
  aws_cmd backup list-backup-jobs \
    --output json 2>/dev/null || echo '{"BackupJobs":[]}'
}

get_metric() {
  local metric="$1" stat_type="${2:-Sum}"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/Backup \
    --metric-name "$metric" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics "$stat_type" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {print int(s)}'; }
calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.0f", s/c; else print "0"}'; }

record_issue() {
  ISSUES+=("$1")
}

analyze_vault() {
  local vault_json="$1"
  local vault_name vault_arn created_date encryption_key
  vault_name=$(echo "${vault_json}" | jq_safe '.BackupVaultName')
  vault_arn=$(echo "${vault_json}" | jq_safe '.BackupVaultArn')
  created_date=$(echo "${vault_json}" | jq_safe '.CreationDate')
  encryption_key=$(echo "${vault_json}" | jq_safe '.EncryptionKeyArn')

  TOTAL_VAULTS=$((TOTAL_VAULTS + 1))
  log_message INFO "Analyzing vault ${vault_name}"

  {
    echo "Vault: ${vault_name}"
    echo "  ARN: ${vault_arn}"
    echo "  Created: ${created_date}"
    if [[ -n "${encryption_key}" && "${encryption_key}" != "null" ]]; then
      echo "  Encryption Key: ${encryption_key}"
    else
      echo "  Encryption Key: AWS Managed (Default)"
    fi
  } >> "${OUTPUT_FILE}"

  # Check encryption compliance
  if [[ "${VAULT_ENCRYPTION_REQUIRED}" == "true" ]]; then
    if [[ -z "${encryption_key}" || "${encryption_key}" == "null" ]]; then
      UNENCRYPTED_VAULTS=$((UNENCRYPTED_VAULTS + 1))
      record_issue "Vault ${vault_name} not using customer-managed encryption key"
      echo "  COMPLIANCE: ⚠️ Not using customer-managed encryption" >> "${OUTPUT_FILE}"
    else
      echo "  COMPLIANCE: ✓ Customer-managed encryption enabled" >> "${OUTPUT_FILE}"
    fi
  fi

  # Get recovery points
  local rp_json
  rp_json=$(list_recovery_points "${vault_name}")
  local rp_count
  rp_count=$(echo "${rp_json}" | jq '.RecoveryPoints | length' 2>/dev/null || echo 0)

  {
    echo "  Recovery Points: ${rp_count}"
  } >> "${OUTPUT_FILE}"

  # Check for stale recovery points
  local stale_count
  stale_count=$(echo "${rp_json}" | jq "[.RecoveryPoints[] | select(.CreationDate < \"$(date -u -d "${DAYS_SINCE_SUCCESS_WARN} days ago" +%Y-%m-%dT%H:%M:%SZ)\")] | length" 2>/dev/null || echo 0)
  if (( stale_count > 0 )); then
    echo "  Stale Recovery Points (> ${DAYS_SINCE_SUCCESS_WARN}d): ${stale_count}" >> "${OUTPUT_FILE}"
  fi

  echo "" >> "${OUTPUT_FILE}"
}

analyze_backup_plan() {
  local plan_json="$1"
  local plan_id plan_name plan_version creation_date
  plan_id=$(echo "${plan_json}" | jq_safe '.BackupPlanId')
  plan_name=$(echo "${plan_json}" | jq_safe '.BackupPlanName')
  plan_version=$(echo "${plan_json}" | jq_safe '.VersionId')
  creation_date=$(echo "${plan_json}" | jq_safe '.CreationDate')

  TOTAL_BACKUP_PLANS=$((TOTAL_BACKUP_PLANS + 1))
  log_message INFO "Analyzing backup plan ${plan_name}"

  {
    echo "Backup Plan: ${plan_name}"
    echo "  ID: ${plan_id}"
    echo "  Version: ${plan_version}"
    echo "  Created: ${creation_date}"
  } >> "${OUTPUT_FILE}"

  # Get full plan details
  local full_plan
  full_plan=$(get_backup_plan "${plan_id}")
  local rules_count
  rules_count=$(echo "${full_plan}" | jq '.BackupPlan.Rules | length' 2>/dev/null || echo 0)

  {
    echo "  Rules: ${rules_count}"
  } >> "${OUTPUT_FILE}"

  echo "${full_plan}" | jq -c '.BackupPlan.Rules[]?' 2>/dev/null | while read -r rule; do
    local rule_name target_vault frequency retention days
    rule_name=$(echo "${rule}" | jq_safe '.RuleName')
    target_vault=$(echo "${rule}" | jq_safe '.TargetBackupVaultName')
    frequency=$(echo "${rule}" | jq_safe '.ScheduleExpression')
    retention=$(echo "${rule}" | jq_safe '.Lifecycle.DeleteAfterDays')
    days=$(echo "${rule}" | jq_safe '.Lifecycle.MoveToColdStorageAfterDays')

    {
      echo "    Rule: ${rule_name}"
      echo "      Target Vault: ${target_vault}"
      echo "      Schedule: ${frequency}"
      if [[ -n "${retention}" && "${retention}" != "null" ]]; then
        echo "      Retention: ${retention} days"
      fi
      if [[ -n "${days}" && "${days}" != "null" ]]; then
        echo "      Move to Cold: ${days} days"
      fi
    } >> "${OUTPUT_FILE}"

    # Check cross-region copy
    local copy_config
    copy_config=$(echo "${rule}" | jq '.CopyActions[]?' 2>/dev/null || echo "")
    if [[ -n "${copy_config}" ]]; then
      {
        echo "      Cross-Region Copy: Enabled"
      } >> "${OUTPUT_FILE}"
    elif [[ "${CROSS_REGION_COPY_REQUIRED}" == "true" ]]; then
      record_issue "Plan ${plan_name} rule ${rule_name} missing cross-region copy"
      {
        echo "      Cross-Region Copy: ⚠️ Not configured"
      } >> "${OUTPUT_FILE}"
    fi
  done

  # Get resources assigned to plan
  local resources_json
  resources_json=$(list_backup_plan_resources "${plan_id}")
  local resource_count
  resource_count=$(echo "${resources_json}" | jq '.Resources | length' 2>/dev/null || echo 0)

  {
    echo "  Resources: ${resource_count}"
  } >> "${OUTPUT_FILE}"

  echo "" >> "${OUTPUT_FILE}"
}

analyze_backup_jobs() {
  log_message INFO "Analyzing backup jobs"
  {
    echo "Backup Jobs"
    echo "==========="
  } >> "${OUTPUT_FILE}"

  local jobs_json
  jobs_json=$(list_backup_jobs)
  local job_count
  job_count=$(echo "${jobs_json}" | jq '.BackupJobs | length' 2>/dev/null || echo 0)

  TOTAL_BACKUP_JOBS="${job_count}"

  {
    echo "Total Jobs (24h): ${job_count}"
  } >> "${OUTPUT_FILE}"

  # Count by status
  local created completed failed expired
  created=$(echo "${jobs_json}" | jq '[.BackupJobs[] | select(.State == "CREATED")] | length' 2>/dev/null || echo 0)
  completed=$(echo "${jobs_json}" | jq '[.BackupJobs[] | select(.State == "COMPLETED")] | length' 2>/dev/null || echo 0)
  failed=$(echo "${jobs_json}" | jq '[.BackupJobs[] | select(.State == "FAILED")] | length' 2>/dev/null || echo 0)
  expired=$(echo "${jobs_json}" | jq '[.BackupJobs[] | select(.State == "EXPIRED")] | length' 2>/dev/null || echo 0)

  {
    echo "  Created: ${created}"
    echo "  Completed: ${completed}"
    echo "  Failed: ${failed}"
    echo "  Expired: ${expired}"
  } >> "${OUTPUT_FILE}"

  FAILED_BACKUP_JOBS="${failed}"

  if (( failed > FAILED_JOBS_WARN )); then
    record_issue "Backup jobs: ${failed} failed (threshold ${FAILED_JOBS_WARN})"
    echo "  COMPLIANCE: ⚠️ Failed jobs exceed threshold" >> "${OUTPUT_FILE}"
  fi

  # List recent failed jobs
  if (( failed > 0 )); then
    {
      echo ""
      echo "  Failed Jobs:"
    } >> "${OUTPUT_FILE}"

    echo "${jobs_json}" | jq -c '.BackupJobs[] | select(.State == "FAILED")' 2>/dev/null | head -10 | while read -r job; do
      local job_id resource_arn resource_type creation_date status_message
      job_id=$(echo "${job}" | jq_safe '.BackupJobId')
      resource_arn=$(echo "${job}" | jq_safe '.ResourceArn')
      resource_type=$(echo "${job}" | jq_safe '.ResourceType')
      creation_date=$(echo "${job}" | jq_safe '.CreationDate')
      status_message=$(echo "${job}" | jq_safe '.StatusMessage')

      {
        echo "    Job: ${job_id}"
        echo "      Resource: ${resource_type}:${resource_arn}"
        echo "      Created: ${creation_date}"
        if [[ -n "${status_message}" && "${status_message}" != "null" ]]; then
          echo "      Message: ${status_message}"
        fi
      } >> "${OUTPUT_FILE}"
    done
  fi

  echo "" >> "${OUTPUT_FILE}"
}

analyze_cloudwatch_metrics() {
  log_message INFO "Pulling CloudWatch metrics"
  {
    echo "CloudWatch Metrics"
    echo "=================="
  } >> "${OUTPUT_FILE}"

  local created_jobs completed_jobs failed_jobs restore_created restore_failed
  created_jobs=$(get_metric "BackupJobsCreated" "Sum" | calculate_sum)
  completed_jobs=$(get_metric "BackupJobsCompleted" "Sum" | calculate_sum)
  failed_jobs=$(get_metric "BackupJobsFailed" "Sum" | calculate_sum)
  restore_created=$(get_metric "RestoreJobsCreated" "Sum" | calculate_sum)
  restore_failed=$(get_metric "RestoreJobsFailed" "Sum" | calculate_sum)

  {
    echo "Backup Jobs (${LOOKBACK_HOURS}h):"
    echo "  Created: ${created_jobs}"
    echo "  Completed: ${completed_jobs}"
    echo "  Failed: ${failed_jobs}"
    echo ""
    echo "Restore Jobs (${LOOKBACK_HOURS}h):"
    echo "  Created: ${restore_created}"
    echo "  Failed: ${restore_failed}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  write_header

  # Analyze vaults
  log_message INFO "Listing backup vaults"
  local vaults_json
  vaults_json=$(list_backup_vaults)
  local vault_count
  vault_count=$(echo "${vaults_json}" | jq '.BackupVaultList | length' 2>/dev/null || echo 0)

  if [[ "${vault_count}" == "0" ]]; then
    log_message WARN "No backup vaults found"
    echo "No backup vaults found." >> "${OUTPUT_FILE}"
  else
    {
      echo "Backup Vaults"
      echo "============="
      echo "Total Vaults: ${vault_count}"
      echo ""
    } >> "${OUTPUT_FILE}"

    echo "${vaults_json}" | jq -c '.BackupVaultList[]' 2>/dev/null | while read -r vault; do
      analyze_vault "${vault}"
    done
  fi

  # Analyze plans
  log_message INFO "Listing backup plans"
  local plans_json
  plans_json=$(list_backup_plans)
  local plan_count
  plan_count=$(echo "${plans_json}" | jq '.BackupPlansList | length' 2>/dev/null || echo 0)

  if [[ "${plan_count}" == "0" ]]; then
    log_message WARN "No backup plans found"
    echo "No backup plans found." >> "${OUTPUT_FILE}"
  else
    {
      echo "Backup Plans"
      echo "============"
      echo "Total Plans: ${plan_count}"
      echo ""
    } >> "${OUTPUT_FILE}"

    echo "${plans_json}" | jq -c '.BackupPlansList[]' 2>/dev/null | while read -r plan; do
      analyze_backup_plan "${plan}"
    done
  fi

  # Analyze backup jobs
  analyze_backup_jobs

  # CloudWatch metrics
  analyze_cloudwatch_metrics

  # Summary
  {
    echo "Compliance Summary"
    echo "=================="
    echo "Total Vaults: ${TOTAL_VAULTS}"
    echo "Unencrypted Vaults: ${UNENCRYPTED_VAULTS}"
    echo ""
    echo "Total Backup Plans: ${TOTAL_BACKUP_PLANS}"
    echo ""
    echo "Total Backup Jobs (24h): ${TOTAL_BACKUP_JOBS}"
    echo "Failed Jobs: ${FAILED_BACKUP_JOBS}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "Backup Compliance Audit detected issues:\n${joined}" "WARNING"
    send_email_alert "Backup Compliance Audit Alerts" "${joined}" || true
  else
    log_message INFO "No compliance issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"
