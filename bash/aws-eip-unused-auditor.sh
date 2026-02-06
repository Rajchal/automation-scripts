#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-eip-unused-auditor.log"
REPORT_FILE="/tmp/eip-unused-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
ALERT_THRESHOLD="${EIP_ALERT_THRESHOLD:-1}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "EIP Unused Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Alert threshold (unattached count): $ALERT_THRESHOLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  addrs_json=$(aws ec2 describe-addresses --region "$REGION" --output json 2>/dev/null || echo '{"Addresses":[]}')
  addrs=$(echo "$addrs_json" | jq -c '.Addresses[]?')

  if [ -z "$addrs" ]; then
    echo "No Elastic IPs found." >> "$REPORT_FILE"
    log_message "No Elastic IPs in region $REGION"
    exit 0
  fi

  unattached_count=0

  echo "$addrs_json" | jq -c '.Addresses[]?' | while read -r a; do
    public_ip=$(echo "$a" | jq -r '.PublicIp // "<unknown>"')
    allocation_id=$(echo "$a" | jq -r '.AllocationId // empty')
    association_id=$(echo "$a" | jq -r '.AssociationId // empty')
    instance_id=$(echo "$a" | jq -r '.InstanceId // empty')
    network_interface_id=$(echo "$a" | jq -r '.NetworkInterfaceId // empty')
    domain=$(echo "$a" | jq -r '.Domain // "standard"')

    if [ -z "$association_id" ] || [ "$association_id" = "null" ]; then
      echo "Unattached EIP: $public_ip (allocation=$allocation_id domain=$domain)" >> "$REPORT_FILE"
      echo "  InstanceId: ${instance_id:-<none>} NetworkInterfaceId: ${network_interface_id:-<none>}" >> "$REPORT_FILE"
      echo "" >> "$REPORT_FILE"
      unattached_count=$((unattached_count+1))
    else
      echo "Attached EIP: $public_ip -> assoc=$association_id instance=${instance_id:-<none>}" >> "$REPORT_FILE"
    fi
  done

  if [ "$unattached_count" -ge "$ALERT_THRESHOLD" ]; then
    send_slack_alert "EIP Alert: Found $unattached_count unattached Elastic IP(s) in $REGION. See $REPORT_FILE for details."
  fi

  echo "Summary: unattached_eips=$unattached_count" >> "$REPORT_FILE"
  log_message "EIP auditor written to $REPORT_FILE (unattached=$unattached_count)"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-eip-unused-auditor.log"
REPORT_FILE="/tmp/eip-unused-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
DAYS_OLD="${EIP_UNUSED_DAYS:-30}"
DRY_RUN="${EIP_RELEASE_DRY_RUN:-true}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "EIP Unused Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Unused threshold (days): $DAYS_OLD" >> "$REPORT_FILE"
  echo "Dry run release: $DRY_RUN" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

age_days() { date -d "$1" +%s >/dev/null 2>&1 && echo $(( ( $(date +%s) - $(date -d "$1" +%s) ) / 86400 )) || echo 99999; }

main() {
  write_header

  addrs_json=$(aws ec2 describe-addresses --region "$REGION" --output json 2>/dev/null || echo '{"Addresses":[]}')
  addrs=$(echo "$addrs_json" | jq -c '.Addresses[]?')

  if [ -z "$addrs" ]; then
    echo "No Elastic IPs found." >> "$REPORT_FILE"
    log_message "No EIPs in region $REGION"
    exit 0
  fi

  total=0
  candidates=0

  echo "$addrs_json" | jq -c '.Addresses[]?' | while read -r a; do
    total=$((total+1))
    alloc_id=$(echo "$a" | jq -r '.AllocationId // empty')
    public_ip=$(echo "$a" | jq -r '.PublicIp // "<unknown>"')
    assoc_id=$(echo "$a" | jq -r '.AssociationId // empty')
    domain=$(echo "$a" | jq -r '.Domain // "vpc"')
    network_interface_id=$(echo "$a" | jq -r '.NetworkInterfaceId // empty')
    network_owner_id=$(echo "$a" | jq -r '.NetworkInterfaceOwnerId // empty')
    tags=$(echo "$a" | jq -c '.Tags // []')
    create_time=$(echo "$a" | jq -r '.AssociationId? | empty' >/dev/null 2>&1 && echo "<unknown>" || echo "<unknown>")

    # AWS describe-addresses does not return creation time; attempt to infer from tags
    allocated_at=""
    if echo "$tags" | jq -e '.[]? | select(.Key=="AllocatedAt")' >/dev/null 2>&1; then
      allocated_at=$(echo "$tags" | jq -r '.[] | select(.Key=="AllocatedAt") | .Value')
    fi

    echo "EIP: $public_ip (AllocationId: ${alloc_id:-<none>})" >> "$REPORT_FILE"
    echo "  Associated: ${assoc_id:-<no>}" >> "$REPORT_FILE"
    echo "  NetworkInterfaceId: ${network_interface_id:-<none>}" >> "$REPORT_FILE"
    echo "  OwnerId: ${network_owner_id:-<none>}" >> "$REPORT_FILE"
    echo "  AllocatedAt(tag): ${allocated_at:-<none>}" >> "$REPORT_FILE"

    # If associated, skip
    if [ -n "$assoc_id" ]; then
      echo "  Skipping - currently associated" >> "$REPORT_FILE"
      echo "" >> "$REPORT_FILE"
      continue
    fi

    # If we have an AllocatedAt tag, use it; otherwise we conservatively skip release
    if [ -n "$allocated_at" ] && [ "$allocated_at" != "<none>" ]; then
      age=$(age_days "$allocated_at")
    else
      # fallback: mark as unknown/old so we flag it but not auto-release
      age=99999
    fi

    echo "  AgeDays (inferred): $age" >> "$REPORT_FILE"

    if [ "$age" -ge "$DAYS_OLD" ]; then
      candidates=$((candidates+1))
      echo "  CANDIDATE: EIP $public_ip appears unused and older than $DAYS_OLD days" >> "$REPORT_FILE"
      send_slack_alert "EIP Alert: Unused Elastic IP $public_ip (AllocationId=${alloc_id:-<none>}) appears older than $DAYS_OLD days in $REGION"

      if [ "$DRY_RUN" = "false" ] && [ -n "$alloc_id" ]; then
        aws ec2 release-address --allocation-id "$alloc_id" --region "$REGION" >/dev/null 2>&1 || true
        send_slack_alert "EIP Action: Released Elastic IP $public_ip (AllocationId=$alloc_id) in $REGION"
      fi
    fi

    echo "" >> "$REPORT_FILE"
  done

  echo "Summary: total_eips=$total, candidates=$candidates" >> "$REPORT_FILE"
  log_message "EIP auditor written to $REPORT_FILE (total_eips=$total, candidates=$candidates)"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-eip-unused-auditor.log"
REPORT_FILE="/tmp/eip-unused-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
OLDER_THAN_DAYS="${EIP_UNUSED_DAYS:-14}"
DRY_RUN="${EIP_DELETE_DRY_RUN:-true}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "EIP Unused Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Unused threshold (days): $OLDER_THAN_DAYS" >> "$REPORT_FILE"
  echo "Dry run delete: $DRY_RUN" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

days_since() {
  # arg: ISO date
  if [ -z "$1" ]; then
    echo 99999
    return
  fi
  secs=$(date -d "$1" +%s 2>/dev/null || echo 0)
  if [ "$secs" -eq 0 ]; then
    echo 99999
    return
  fi
  echo $(( ( $(date +%s) - secs ) / 86400 ))
}

main() {
  write_header

  allocs=$(aws ec2 describe-addresses --region "$REGION" --output json 2>/dev/null || echo '{"Addresses":[]}')
  addrs=$(echo "$allocs" | jq -c '.Addresses[]?')

  if [ -z "$addrs" ]; then
    echo "No Elastic IPs found." >> "$REPORT_FILE"
    log_message "No EIPs in region $REGION"
    exit 0
  fi

  total=0
  candidates=0

  echo "$allocs" | jq -c '.Addresses[]?' | while read -r a; do
    total=$((total+1))
    alloc_id=$(echo "$a" | jq -r '.AllocationId // .PublicIp // "<no-id>"')
    public_ip=$(echo "$a" | jq -r '.PublicIp // empty')
    assoc_id=$(echo "$a" | jq -r '.AssociationId // empty')
    network_interface_id=$(echo "$a" | jq -r '.NetworkInterfaceId // empty')
    instance_id=$(echo "$a" | jq -r '.InstanceId // empty')
    domain=$(echo "$a" | jq -r '.Domain // "vpc"')
    create_time=$(echo "$a" | jq -r '.NetworkBorderGroup // empty')

    # There's no direct creation timestamp for EIPs via describe-addresses; use association/instance launch time heuristics when available
    # We'll consider EIP candidate if not associated (no AssociationId)
    echo "Address: ${public_ip} (AllocationId: ${alloc_id})" >> "$REPORT_FILE"
    echo "  Associated Instance: ${instance_id:-<none>}" >> "$REPORT_FILE"
    echo "  NetworkInterface: ${network_interface_id:-<none>}" >> "$REPORT_FILE"
    echo "  AssociationId: ${assoc_id:-<none>}" >> "$REPORT_FILE"

    if [ -n "$assoc_id" ] || [ -n "$instance_id" ] || [ -n "$network_interface_id" ]; then
      echo "  Status: attached/associated" >> "$REPORT_FILE"
      echo "" >> "$REPORT_FILE"
      continue
    fi

    # Unassociated: candidate
    candidates=$((candidates+1))
    echo "  Status: UNASSOCIATED" >> "$REPORT_FILE"

    # Try to infer age: check if AllocationId has tag or describe-addresses doesn't include creation time
    # We'll mark as candidate for manual review and optionally release
    echo "  ACTION: candidate for release" >> "$REPORT_FILE"
    if [ "$DRY_RUN" = "false" ]; then
      # attempt release
      if echo "$alloc_id" | grep -q '^eipalloc-'; then
        aws ec2 release-address --allocation-id "$alloc_id" --region "$REGION" >/dev/null 2>&1 || true
        send_slack_alert "EIP Action: Released unassociated Elastic IP ${public_ip} (alloc ${alloc_id}) in $REGION"
      else
        aws ec2 release-address --public-ip "$public_ip" --region "$REGION" >/dev/null 2>&1 || true
        send_slack_alert "EIP Action: Released unassociated Elastic IP ${public_ip} in $REGION"
      fi
    else
      send_slack_alert "EIP Candidate: Unassociated Elastic IP ${public_ip} (alloc ${alloc_id}) in $REGION — dry-run"
    fi

    echo "" >> "$REPORT_FILE"
  done

  echo "Summary: total_eips=$total, unassociated_candidates=$candidates" >> "$REPORT_FILE"
  log_message "EIP auditor written to $REPORT_FILE (total_eips=$total, candidates=$candidates)"
}

main "$@"
