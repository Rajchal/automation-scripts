#!/bin/bash

################################################################################
# AWS EC2 Security Groups Auditor
# Audits EC2 security groups for overly permissive rules and unused groups
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/ec2-security-groups-audit-$(date +%s).txt"
LOG_FILE="/var/log/ec2-security-groups-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

# API wrappers
describe_security_groups() {
  aws ec2 describe-security-groups --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_network_interfaces() {
  local sg_id="$1"
  aws ec2 describe-network-interfaces \
    --region "${REGION}" \
    --filters "Name=group-id,Values=${sg_id}" \
    --output json 2>/dev/null || echo '{}'
}

describe_instances() {
  local sg_id="$1"
  aws ec2 describe-instances \
    --region "${REGION}" \
    --filters "Name=instance.group-id,Values=${sg_id}" \
    --output json 2>/dev/null || echo '{}'
}

describe_tags() {
  local resource_id="$1"
  aws ec2 describe-tags \
    --region "${REGION}" \
    --filters "Name=resource-id,Values=${resource_id}" \
    --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS EC2 Security Groups Audit"
    echo "============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_security_groups() {
  log_message INFO "Auditing EC2 security groups"
  {
    echo "=== SECURITY GROUPS AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local sg_json
  sg_json=$(describe_security_groups)

  local total_sgs=0 unused_sgs=0 overly_permissive=0 unrestricted_ssh=0 \
        unrestricted_rdp=0 unrestricted_db=0 default_sgs=0 vpc_sgs=0 ec2_classic=0

  echo "${sg_json}" | jq -c '.SecurityGroups[]?' 2>/dev/null | while read -r sg; do
    ((total_sgs++))
    
    local sg_id sg_name group_description vpc_id owner_id
    sg_id=$(echo "${sg}" | jq_safe '.GroupId')
    sg_name=$(echo "${sg}" | jq_safe '.GroupName')
    group_description=$(echo "${sg}" | jq_safe '.GroupDescription')
    vpc_id=$(echo "${sg}" | jq_safe '.VpcId')
    owner_id=$(echo "${sg}" | jq_safe '.OwnerId')

    {
      echo "Security Group: ${sg_name}"
      echo "  ID: ${sg_id}"
      echo "  VPC: ${vpc_id}"
    } >> "${OUTPUT_FILE}"

    # Check if default SG
    if [[ "${sg_name}" == "default" ]]; then
      ((default_sgs++))
      echo "  INFO: Default security group" >> "${OUTPUT_FILE}"
    fi

    if [[ -n "${vpc_id}" && "${vpc_id}" != "null" ]]; then
      ((vpc_sgs++))
    else
      ((ec2_classic++))
      echo "  INFO: EC2-Classic security group" >> "${OUTPUT_FILE}"
    fi

    # Get inbound rules
    local inbound_rules
    inbound_rules=$(echo "${sg}" | jq -c '.IpPermissions[]?' 2>/dev/null)

    local rule_count=0
    echo "${inbound_rules}" | while read -r rule; do
      [[ -z "${rule}" ]] && continue
      ((rule_count++))

      local from_port to_port ip_protocol cidr_ip sg_src ipv6_cidr
      from_port=$(echo "${rule}" | jq_safe '.FromPort')
      to_port=$(echo "${rule}" | jq_safe '.ToPort')
      ip_protocol=$(echo "${rule}" | jq_safe '.IpProtocol')

      # Check IpRanges for 0.0.0.0/0
      local has_unrestricted_cidr=false
      if echo "${rule}" | jq -e '.IpRanges[]? | select(.CidrIp == "0.0.0.0/0")' >/dev/null 2>&1; then
        has_unrestricted_cidr=true
      fi

      # Check IPv6Ranges for ::/0
      if echo "${rule}" | jq -e '.Ipv6Ranges[]? | select(.CidrIpv6 == "::/0")' >/dev/null 2>&1; then
        has_unrestricted_cidr=true
      fi

      if [[ "${has_unrestricted_cidr}" == "true" ]]; then
        local rule_text="${from_port}-${to_port}/${ip_protocol}"
        
        # Detect dangerous rules
        case "${ip_protocol}" in
          tcp)
            if [[ "${from_port}" == "22" || "${to_port}" == "22" ]]; then
              ((unrestricted_ssh++))
              echo "  WARNING: SSH (port 22) unrestricted to 0.0.0.0/0 or ::/0" >> "${OUTPUT_FILE}"
            elif [[ "${from_port}" == "3389" || "${to_port}" == "3389" ]]; then
              ((unrestricted_rdp++))
              echo "  WARNING: RDP (port 3389) unrestricted to 0.0.0.0/0 or ::/0" >> "${OUTPUT_FILE}"
            elif [[ "${from_port}" =~ ^(3306|5432|5984|6379|7000|7001|9042|9160|27017|27018|27019|27020|50070)$ ]]; then
              ((unrestricted_db++))
              echo "  WARNING: Database port unrestricted to 0.0.0.0/0 or ::/0: ${rule_text}" >> "${OUTPUT_FILE}"
            else
              ((overly_permissive++))
              echo "  WARNING: Rule allows unrestricted access: ${rule_text}" >> "${OUTPUT_FILE}"
            fi
            ;;
          -1)
            ((overly_permissive++))
            echo "  WARNING: All traffic (-1) allowed to 0.0.0.0/0 or ::/0" >> "${OUTPUT_FILE}"
            ;;
        esac
      fi
    done

    # Get egress rules
    local egress_rules
    egress_rules=$(echo "${sg}" | jq -c '.IpPermissionsEgress[]?' 2>/dev/null)
    local egress_unrestricted=false

    echo "${egress_rules}" | while read -r rule; do
      [[ -z "${rule}" ]] && continue
      if echo "${rule}" | jq -e '.IpRanges[]? | select(.CidrIp == "0.0.0.0/0")' >/dev/null 2>&1; then
        local ip_protocol from_port to_port
        ip_protocol=$(echo "${rule}" | jq_safe '.IpProtocol')
        if [[ "${ip_protocol}" == "-1" ]]; then
          egress_unrestricted=true
          break
        fi
      fi
    done

    if [[ "${egress_unrestricted}" == "true" ]]; then
      echo "  INFO: Egress allows all traffic to 0.0.0.0/0" >> "${OUTPUT_FILE}"
    fi

    # Check if SG is in use
    local ni_count instances_count
    local ni_response
    ni_response=$(describe_network_interfaces "${sg_id}")
    ni_count=$(echo "${ni_response}" | jq '.NetworkInterfaces | length' 2>/dev/null || echo 0)

    if (( ni_count == 0 )); then
      ((unused_sgs++))
      echo "  WARNING: Security group is not in use (no network interfaces)" >> "${OUTPUT_FILE}"
    else
      echo "  In Use: Yes (${ni_count} network interfaces)" >> "${OUTPUT_FILE}"
    fi

    # Tags
    local tags_response
    tags_response=$(describe_tags "${sg_id}")
    local tag_count
    tag_count=$(echo "${tags_response}" | jq '.Tags | length' 2>/dev/null || echo 0)

    if (( tag_count > 0 )); then
      echo "  Tags: ${tag_count}" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Security Groups Summary:"
    echo "  Total Security Groups: ${total_sgs}"
    echo "  VPC Security Groups: ${vpc_sgs}"
    echo "  EC2-Classic: ${ec2_classic}"
    echo "  Default Groups: ${default_sgs}"
    echo ""
    echo "Security Issues:"
    echo "  Unused Groups: ${unused_sgs}"
    echo "  Unrestricted SSH (22): ${unrestricted_ssh}"
    echo "  Unrestricted RDP (3389): ${unrestricted_rdp}"
    echo "  Unrestricted Database: ${unrestricted_db}"
    echo "  Other Overly Permissive: ${overly_permissive}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_security_group_rules() {
  log_message INFO "Analyzing security group rules"
  {
    echo "=== RULE PATTERNS ==="
  } >> "${OUTPUT_FILE}"

  local sg_json
  sg_json=$(describe_security_groups)

  local rules_allowing_any_ip=0 rules_with_description=0 rules_without_description=0

  echo "${sg_json}" | jq -c '.SecurityGroups[]?' 2>/dev/null | while read -r sg; do
    local sg_id sg_name
    sg_id=$(echo "${sg}" | jq_safe '.GroupId')
    sg_name=$(echo "${sg}" | jq_safe '.GroupName')

    echo "${sg}" | jq -c '.IpPermissions[]?' 2>/dev/null | while read -r rule; do
      [[ -z "${rule}" ]] && continue

      # Count rules with description
      local has_desc
      has_desc=$(echo "${rule}" | jq '.Description' 2>/dev/null)
      if [[ -z "${has_desc}" || "${has_desc}" == "null" ]]; then
        ((rules_without_description++))
      else
        ((rules_with_description++))
      fi

      # Count rules allowing any IP
      if echo "${rule}" | jq -e '.IpRanges[]? | select(.CidrIp == "0.0.0.0/0")' >/dev/null 2>&1; then
        ((rules_allowing_any_ip++))
      fi
      if echo "${rule}" | jq -e '.Ipv6Ranges[]? | select(.CidrIpv6 == "::/0")' >/dev/null 2>&1; then
        ((rules_allowing_any_ip++))
      fi
    done
  done

  {
    echo "Rule Analysis:"
    echo "  Rules Allowing Any IP (0.0.0.0/0 or ::/0): ${rules_allowing_any_ip}"
    echo "  Rules With Description: ${rules_with_description}"
    echo "  Rules Without Description: ${rules_without_description}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_vpc_default_sg() {
  log_message INFO "Checking VPC default security groups"
  {
    echo "=== VPC DEFAULT SECURITY GROUPS ==="
  } >> "${OUTPUT_FILE}"

  local sg_json
  sg_json=$(describe_security_groups)

  local default_with_rules=0

  echo "${sg_json}" | jq -c '.SecurityGroups[] | select(.GroupName == "default" and .VpcId != null)' 2>/dev/null | while read -r sg; do
    local sg_id vpc_id
    sg_id=$(echo "${sg}" | jq_safe '.GroupId')
    vpc_id=$(echo "${sg}" | jq_safe '.VpcId')

    local inbound_count
    inbound_count=$(echo "${sg}" | jq '.IpPermissions | length' 2>/dev/null || echo 0)

    if (( inbound_count > 0 )); then
      ((default_with_rules++))
      echo "Default SG ${sg_id} in VPC ${vpc_id} has ${inbound_count} inbound rules" >> "${OUTPUT_FILE}"
    fi
  done

  if (( default_with_rules == 0 )); then
    echo "All default security groups are properly configured (default deny)" >> "${OUTPUT_FILE}"
  fi
  echo "" >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local unused="$2"; local unrestricted_ssh="$3"; local unrestricted_rdp="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  
  local color="good"
  (( unrestricted_ssh > 0 || unrestricted_rdp > 0 )) && color="danger"
  (( unused > 0 && color == "good" )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS EC2 Security Groups Audit",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Total Groups", "value": "${total}", "short": true},
        {"title": "Unused", "value": "${unused}", "short": true},
        {"title": "Unrestricted SSH", "value": "${unrestricted_ssh}", "short": true},
        {"title": "Unrestricted RDP", "value": "${unrestricted_rdp}", "short": true},
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
  log_message INFO "Starting EC2 security groups audit"
  write_header
  audit_security_groups
  audit_security_group_rules
  check_vpc_default_sg
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total unused unrestricted_ssh unrestricted_rdp
  total=$(grep "Total Security Groups:" "${OUTPUT_FILE}" | awk '{print $NF}')
  unused=$(grep "Unused Groups:" "${OUTPUT_FILE}" | awk '{print $NF}')
  unrestricted_ssh=$(grep "Unrestricted SSH" "${OUTPUT_FILE}" | awk '{print $NF}' | head -1)
  unrestricted_rdp=$(grep "Unrestricted RDP" "${OUTPUT_FILE}" | awk '{print $NF}' | head -1)
  [[ -z "${total}" ]] && total=0
  [[ -z "${unused}" ]] && unused=0
  [[ -z "${unrestricted_ssh}" ]] && unrestricted_ssh=0
  [[ -z "${unrestricted_rdp}" ]] && unrestricted_rdp=0
  send_slack_alert "${total}" "${unused}" "${unrestricted_ssh}" "${unrestricted_rdp}"
  cat "${OUTPUT_FILE}"
}

main "$@"
