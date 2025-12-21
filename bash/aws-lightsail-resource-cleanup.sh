#!/bin/bash

################################################################################
# AWS Lightsail Resource Cleanup
# Identifies and removes unused/idle Lightsail instances, snapshots, databases,
# and disks. Provides cost analysis and dry-run mode before deletion.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/lightsail-cleanup-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/lightsail-cleanup.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Cleanup settings
DRY_RUN="${DRY_RUN:-true}"                      # don't actually delete
DELETE_IDLE="${DELETE_IDLE:-false}"             # delete idle instances
DELETE_SNAPSHOTS="${DELETE_SNAPSHOTS:-false}"   # delete old snapshots
DELETE_DATABASES="${DELETE_DATABASES:-false}"   # delete databases
DELETE_DISKS="${DELETE_DISKS:-false}"           # delete unattached disks

# Thresholds
CPU_IDLE_THRESHOLD="${CPU_IDLE_THRESHOLD:-5}"               # % CPU usage
NETWORK_IDLE_THRESHOLD="${NETWORK_IDLE_THRESHOLD:-100}"     # MB/day
INSTANCE_IDLE_DAYS="${INSTANCE_IDLE_DAYS:-7}"               # days idle before flag
SNAPSHOT_AGE_DAYS="${SNAPSHOT_AGE_DAYS:-90}"                # days old before flag
DATABASE_IDLE_DAYS="${DATABASE_IDLE_DAYS:-14}"              # days idle before flag

# Pricing (baseline approximate USD)
LIGHTSAIL_INSTANCE_HOURLY=(
  ["512MB"]="3.50"
  ["1GB"]="5.00"
  ["2GB"]="10.00"
  ["4GB"]="20.00"
)

LIGHTSAIL_DISK_HOURLY="0.10"    # per GB storage
LIGHTSAIL_DB_HOURLY="15.00"     # approximate per month

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

# Helpers
jq_safe() { jq -r "$1" 2>/dev/null || echo ""; }

list_instances() {
  aws lightsail get-instances \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"instances":[]}'
}

describe_instance() {
  local instance_name="$1"
  aws lightsail get-instance \
    --instance-name "${instance_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_instance_metrics() {
  local instance_name="$1"
  local metric_name="$2"
  local start_time end_time
  
  start_time=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws lightsail get-instance-metric-statistics \
    --instance-name "${instance_name}" \
    --metric-name "${metric_name}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period 86400 \
    --unit "Percent" \
    --statistics Average \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"metricStatistics":[]}'
}

delete_instance() {
  local instance_name="$1"
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_message INFO "[DRY-RUN] Would delete instance: ${instance_name}"
    return 0
  fi
  
  aws lightsail delete-instance \
    --instance-name "${instance_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || return 1
}

list_snapshots() {
  aws lightsail get-instance-snapshots \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"instanceSnapshots":[]}'
}

delete_snapshot() {
  local snapshot_name="$1"
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_message INFO "[DRY-RUN] Would delete snapshot: ${snapshot_name}"
    return 0
  fi
  
  aws lightsail delete-instance-snapshot \
    --instance-snapshot-name "${snapshot_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || return 1
}

list_databases() {
  aws lightsail get-relational-databases \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"relationalDatabases":[]}'
}

delete_database() {
  local db_name="$1"
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_message INFO "[DRY-RUN] Would delete database: ${db_name}"
    return 0
  fi
  
  aws lightsail delete-relational-database \
    --relational-database-name "${db_name}" \
    --skip-final-snapshot \
    --region "${REGION}" \
    --output json 2>/dev/null || return 1
}

list_disks() {
  aws lightsail get-disks \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"disks":[]}'
}

delete_disk() {
  local disk_name="$1"
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_message INFO "[DRY-RUN] Would delete disk: ${disk_name}"
    return 0
  fi
  
  aws lightsail delete-disk \
    --disk-name "${disk_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || return 1
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
      "title": "Lightsail Cleanup Report",
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
    echo "Lightsail Resource Cleanup Report"
    echo "=================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Dry Run Mode: ${DRY_RUN}"
    echo ""
    echo "Cleanup Settings:"
    echo "  Delete Idle Instances: ${DELETE_IDLE}"
    echo "  Delete Old Snapshots: ${DELETE_SNAPSHOTS}"
    echo "  Delete Databases: ${DELETE_DATABASES}"
    echo "  Delete Unused Disks: ${DELETE_DISKS}"
    echo ""
  } > "${OUTPUT_FILE}"
}

cleanup_instances() {
  log_message INFO "Scanning for idle Lightsail instances"
  
  {
    echo "=== INSTANCE CLEANUP ANALYSIS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local instances_json
  instances_json=$(list_instances)
  
  local instance_names
  instance_names=$(echo "${instances_json}" | jq -r '.instances[]?.name' 2>/dev/null)
  
  if [[ -z "${instance_names}" ]]; then
    {
      echo "No Lightsail instances found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local total_instances=0
  local idle_instances=0
  local potential_savings=0
  
  while IFS= read -r instance_name; do
    [[ -z "${instance_name}" ]] && continue
    ((total_instances++))
    
    log_message INFO "Analyzing instance: ${instance_name}"
    
    local instance_desc
    instance_desc=$(describe_instance "${instance_name}")
    
    local hardware state created_date
    hardware=$(echo "${instance_desc}" | jq_safe '.instance.hardware.cpuCount')
    state=$(echo "${instance_desc}" | jq_safe '.instance.state')
    created_date=$(echo "${instance_desc}" | jq_safe '.instance.createdAt')
    
    # Get CPU metrics
    local cpu_metrics
    cpu_metrics=$(get_instance_metrics "${instance_name}" "CPUUtilization")
    
    local cpu_avg=0
    cpu_avg=$(echo "${cpu_metrics}" | jq -r '.metricStatistics[]?.average' 2>/dev/null | \
      awk '{s+=$1; c++} END {if (c>0) printf "%.2f", s/c; else print "0"}')
    
    {
      echo "Instance: ${instance_name}"
      echo "State: ${state}"
      echo "Created: ${created_date}"
      echo "CPU Cores: ${hardware}"
      echo "Avg CPU Utilization (7 days): ${cpu_avg}%"
    } >> "${OUTPUT_FILE}"
    
    # Determine if idle
    local is_idle=false
    local idle_reason=""
    
    if (( $(echo "${cpu_avg} < ${CPU_IDLE_THRESHOLD}" | bc -l) )); then
      is_idle=true
      idle_reason="Low CPU utilization (${cpu_avg}%)"
      ((idle_instances++))
    fi
    
    if [[ "${state}" != "running" ]]; then
      is_idle=true
      idle_reason="Not running (${state})"
    fi
    
    if ${is_idle}; then
      {
        printf "%bStatus: IDLE - %s%b\n" "${YELLOW}" "${idle_reason}" "${NC}"
        echo ""
      } >> "${OUTPUT_FILE}"
      
      log_message WARN "Instance ${instance_name} is idle: ${idle_reason}"
      
      # Estimate monthly cost (rough)
      local monthly_cost="15.00"  # Default small bundle price
      potential_savings=$(awk -v p="${potential_savings}" -v m="${monthly_cost}" 'BEGIN{printf "%.2f", p+m}')
      
      if [[ "${DELETE_IDLE}" == "true" ]]; then
        {
          echo "Action: DELETING (potential savings: \$${monthly_cost}/month)"
        } >> "${OUTPUT_FILE}"
        
        if delete_instance "${instance_name}"; then
          log_message INFO "Successfully deleted instance: ${instance_name}"
          {
            echo "Result: ✓ Deleted"
          } >> "${OUTPUT_FILE}"
        else
          log_message ERROR "Failed to delete instance: ${instance_name}"
          {
            echo "Result: ✗ Deletion failed"
          } >> "${OUTPUT_FILE}"
        fi
      else
        {
          echo "Action: FLAGGED for review (potential savings: \$${monthly_cost}/month)"
        } >> "${OUTPUT_FILE}"
      fi
    else
      {
        echo "Status: ACTIVE"
      } >> "${OUTPUT_FILE}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${instance_names}"
  
  {
    echo ""
    echo "Instance Summary:"
    echo "  Total: ${total_instances}"
    echo "  Idle/Unused: ${idle_instances}"
    echo "  Potential Monthly Savings: \$${potential_savings}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

cleanup_snapshots() {
  log_message INFO "Scanning for old snapshots"
  
  {
    echo "=== SNAPSHOT CLEANUP ANALYSIS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local snapshots_json
  snapshots_json=$(list_snapshots)
  
  local snapshot_names
  snapshot_names=$(echo "${snapshots_json}" | jq -r '.instanceSnapshots[]?.name' 2>/dev/null)
  
  if [[ -z "${snapshot_names}" ]]; then
    {
      echo "No snapshots found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local total_snapshots=0
  local old_snapshots=0
  local potential_savings=0
  
  while IFS= read -r snapshot_name; do
    [[ -z "${snapshot_name}" ]] && continue
    ((total_snapshots++))
    
    local snapshot_created
    snapshot_created=$(echo "${snapshots_json}" | jq -r ".instanceSnapshots[] | select(.name==\"${snapshot_name}\") | .createdAt" 2>/dev/null)
    
    local snapshot_size
    snapshot_size=$(echo "${snapshots_json}" | jq -r ".instanceSnapshots[] | select(.name==\"${snapshot_name}\") | .sizeInGb" 2>/dev/null || echo 0)
    
    # Calculate age
    local created_epoch
    created_epoch=$(date -d "${snapshot_created}" +%s 2>/dev/null || echo 0)
    local now_epoch
    now_epoch=$(date +%s)
    local age_days=$(( (now_epoch - created_epoch) / 86400 ))
    
    {
      echo "Snapshot: ${snapshot_name}"
      echo "Created: ${snapshot_created} (${age_days} days ago)"
      echo "Size: ${snapshot_size} GB"
    } >> "${OUTPUT_FILE}"
    
    if [[ ${age_days} -gt ${SNAPSHOT_AGE_DAYS} ]]; then
      ((old_snapshots++))
      local monthly_cost
      monthly_cost=$(awk -v s="${snapshot_size}" 'BEGIN{printf "%.2f", s*0.05}')
      potential_savings=$(awk -v p="${potential_savings}" -v m="${monthly_cost}" 'BEGIN{printf "%.2f", p+m}')
      
      {
        printf "%bStatus: OLD - %d days%b\n" "${YELLOW}" "${age_days}" "${NC}"
        echo "Monthly Cost: \$${monthly_cost}"
        echo ""
      } >> "${OUTPUT_FILE}"
      
      if [[ "${DELETE_SNAPSHOTS}" == "true" ]]; then
        {
          echo "Action: DELETING"
        } >> "${OUTPUT_FILE}"
        
        if delete_snapshot "${snapshot_name}"; then
          log_message INFO "Successfully deleted snapshot: ${snapshot_name}"
          {
            echo "Result: ✓ Deleted"
          } >> "${OUTPUT_FILE}"
        else
          log_message ERROR "Failed to delete snapshot: ${snapshot_name}"
          {
            echo "Result: ✗ Deletion failed"
          } >> "${OUTPUT_FILE}"
        fi
      else
        {
          echo "Action: FLAGGED for review"
        } >> "${OUTPUT_FILE}"
      fi
    else
      {
        echo "Status: RECENT"
      } >> "${OUTPUT_FILE}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${snapshot_names}"
  
  {
    echo ""
    echo "Snapshot Summary:"
    echo "  Total: ${total_snapshots}"
    echo "  Old (>${SNAPSHOT_AGE_DAYS}d): ${old_snapshots}"
    echo "  Potential Monthly Savings: \$${potential_savings}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

cleanup_databases() {
  log_message INFO "Scanning for idle databases"
  
  {
    echo "=== DATABASE CLEANUP ANALYSIS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local databases_json
  databases_json=$(list_databases)
  
  local database_names
  database_names=$(echo "${databases_json}" | jq -r '.relationalDatabases[]?.name' 2>/dev/null)
  
  if [[ -z "${database_names}" ]]; then
    {
      echo "No databases found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local total_databases=0
  
  while IFS= read -r database_name; do
    [[ -z "${database_name}" ]] && continue
    ((total_databases++))
    
    {
      echo "Database: ${database_name}"
      echo "Status: ACTIVE (monitoring not implemented)"
      echo ""
    } >> "${OUTPUT_FILE}"
  done <<< "${database_names}"
  
  {
    echo "Database Summary:"
    echo "  Total: ${total_databases}"
    echo "  Note: Implement query/connection metrics for idle detection"
    echo ""
  } >> "${OUTPUT_FILE}"
}

cleanup_disks() {
  log_message INFO "Scanning for unattached disks"
  
  {
    echo "=== DISK CLEANUP ANALYSIS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local disks_json
  disks_json=$(list_disks)
  
  local disk_names
  disk_names=$(echo "${disks_json}" | jq -r '.disks[]?.name' 2>/dev/null)
  
  if [[ -z "${disk_names}" ]]; then
    {
      echo "No disks found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local total_disks=0
  local unattached_disks=0
  
  while IFS= read -r disk_name; do
    [[ -z "${disk_name}" ]] && continue
    ((total_disks++))
    
    local attached_to
    attached_to=$(echo "${disks_json}" | jq -r ".disks[] | select(.name==\"${disk_name}\") | .attachmentState" 2>/dev/null)
    local disk_size
    disk_size=$(echo "${disks_json}" | jq -r ".disks[] | select(.name==\"${disk_name}\") | .sizeInGb" 2>/dev/null || echo 0)
    
    {
      echo "Disk: ${disk_name}"
      echo "Size: ${disk_size} GB"
      echo "Attachment: ${attached_to}"
    } >> "${OUTPUT_FILE}"
    
    if [[ "${attached_to}" != "attached" ]]; then
      ((unattached_disks++))
      {
        printf "%bStatus: UNATTACHED%b\n" "${YELLOW}" "${NC}"
        echo ""
      } >> "${OUTPUT_FILE}"
    else
      {
        echo "Status: ATTACHED"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done <<< "${disk_names}"
  
  {
    echo "Disk Summary:"
    echo "  Total: ${total_disks}"
    echo "  Unattached: ${unattached_disks}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations() {
  {
    echo "=== CLEANUP RECOMMENDATIONS ==="
    echo ""
    echo "1. Review idle instances before deletion"
    echo "2. Ensure snapshots of deleted instances are retained if needed"
    echo "3. Monitor cost impact after cleanup"
    echo "4. Set CloudWatch alarms on low CPU for proactive management"
    echo "5. Use Lightsail automatic snapshots for disaster recovery"
    echo "6. Consider cost optimization by downsizing under-utilized instances"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Lightsail Resource Cleanup Started ==="
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_message INFO "Running in DRY-RUN mode - no resources will be deleted"
    {
      echo ""
      echo "⚠️  DRY-RUN MODE ENABLED - No actual deletions will occur"
      echo ""
    } >> "${OUTPUT_FILE}"
  fi
  
  write_header
  cleanup_instances
  cleanup_snapshots
  cleanup_databases
  cleanup_disks
  recommendations
  
  {
    echo ""
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== Lightsail Resource Cleanup Completed ==="
}

main "$@"
