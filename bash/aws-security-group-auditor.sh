#!/usr/bin/env bash
set -euo pipefail

# aws-security-group-auditor.sh
# Audit security groups for risky rules (e.g., 0.0.0.0/0, unused SGs).
# Optionally remediate by removing overly permissive rules or deleting unused groups.
# Dry-run by default; use --no-dry-run to apply changes.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--find-open-rules] [--find-unused] [--remediate] [--no-dry-run]

Options:
  --region REGION       AWS region (uses AWS_DEFAULT_REGION if unset)
  --find-open-rules     Find rules allowing 0.0.0.0/0 or ::/0 (default: all checks)
  --find-unused         Find unused security groups (no attached instances)
  --remediate           Remove flagged rules or delete unused groups (requires --no-dry-run)
  --no-dry-run          Apply changes (default is dry-run only)
  -h, --help            Show this help

Examples:
  # Dry-run: audit for open rules and unused groups
  bash/aws-security-group-auditor.sh

  # Find only overly open ingress rules
  bash/aws-security-group-auditor.sh --find-open-rules

  # Find and report unused security groups
  bash/aws-security-group-auditor.sh --find-unused

  # Remove unused groups (dangerous - review first)
  bash/aws-security-group-auditor.sh --find-unused --remediate --no-dry-run

EOF
}

REGION=""
FIND_OPEN_RULES=true
FIND_UNUSED=true
REMEDIATE=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --find-open-rules) FIND_OPEN_RULES=true; FIND_UNUSED=false; shift;;
    --find-unused) FIND_UNUSED=true; FIND_OPEN_RULES=false; shift;;
    --remediate) REMEDIATE=true; shift;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required"; exit 3
fi

EC2=(aws ec2)
if [[ -n "$REGION" ]]; then
  EC2+=(--region "$REGION")
fi

echo "Security group auditor: find-open-rules=$FIND_OPEN_RULES find-unused=$FIND_UNUSED remediate=$REMEDIATE dry-run=$DRY_RUN"

declare -a open_sgs
declare -a unused_sgs

# Get all security groups
sgs_json=$("${EC2[@]}" describe-security-groups --output json 2>/dev/null || echo '{}')
mapfile -t sgs < <(echo "$sgs_json" | jq -c '.SecurityGroups[]?')

if [[ ${#sgs[@]} -eq 0 ]]; then
  echo "No security groups found."; exit 0
fi

# Check for open rules
if [[ "$FIND_OPEN_RULES" == true ]]; then
  echo ""
  echo "Checking for overly permissive ingress rules..."
  for sg_json in "${sgs[@]}"; do
    sg_id=$(echo "$sg_json" | jq -r '.GroupId')
    sg_name=$(echo "$sg_json" | jq -r '.GroupName')
    
    mapfile -t rules < <(echo "$sg_json" | jq -c '.IpPermissions[]? | select(.IpRanges[]? | select(.CidrIp == "0.0.0.0/0" or .CidrIp == "::/0")) or select(.Ipv6Ranges[]? | select(.CidrIpv6 == "::/0"))')
    
    if [[ ${#rules[@]} -gt 0 ]]; then
      echo "  OPEN: $sg_id ($sg_name) has ${#rules[@]} rule(s) allowing 0.0.0.0/0"
      for rule in "${rules[@]}"; do
        proto=$(echo "$rule" | jq -r '.IpProtocol // "-"')
        from_port=$(echo "$rule" | jq -r '.FromPort // "N/A"')
        to_port=$(echo "$rule" | jq -r '.ToPort // "N/A"')
        echo "    - Protocol=$proto Ports=$from_port:$to_port"
      done
      open_sgs+=("$sg_id|$sg_name")
    fi
  done
fi

# Check for unused groups
if [[ "$FIND_UNUSED" == true ]]; then
  echo ""
  echo "Checking for unused security groups..."
  for sg_json in "${sgs[@]}"; do
    sg_id=$(echo "$sg_json" | jq -r '.GroupId')
    sg_name=$(echo "$sg_json" | jq -r '.GroupName')
    
    # Check for attached instances/ENIs
    attached=$("${EC2[@]}" describe-network-interfaces --filters "Name=group-id,Values=$sg_id" --output json 2>/dev/null | jq '.NetworkInterfaces | length')
    
    # Skip default group
    if [[ "$sg_name" == "default" ]]; then
      continue
    fi
    
    if [[ "$attached" -eq 0 ]]; then
      echo "  UNUSED: $sg_id ($sg_name) - no attached ENIs"
      unused_sgs+=("$sg_id|$sg_name")
    fi
  done
fi

echo ""
echo "Summary: ${#open_sgs[@]} open rule(s), ${#unused_sgs[@]} unused group(s)"

if [[ "$REMEDIATE" == true && "$DRY_RUN" == false ]]; then
  echo ""
  echo "Applying remediation..."
  
  if [[ "$FIND_UNUSED" == true ]]; then
    for sg in "${unused_sgs[@]}"; do
      IFS='|' read -r sg_id sg_name <<< "$sg"
      echo "  Deleting unused SG: $sg_id ($sg_name)"
      "${EC2[@]}" delete-security-group --group-id "$sg_id" 2>/dev/null || echo "    Failed to delete $sg_id"
    done
  fi
fi

echo "Done."
