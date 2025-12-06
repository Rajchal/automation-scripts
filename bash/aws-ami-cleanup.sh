#!/usr/bin/env bash
set -euo pipefail

# aws-ami-cleanup.sh
# Find and deregister unused/old AMIs and delete associated snapshots.
# Checks if AMI is in use by any EC2 instances or launch templates.
# Dry-run by default; use --no-dry-run to deregister AMIs.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--older-than-days N] [--name-filter PATTERN] [--no-dry-run]

Options:
  --region REGION          AWS region (uses AWS_DEFAULT_REGION if unset)
  --older-than-days N      Only consider AMIs older than N days (default: 90)
  --name-filter PATTERN    Only consider AMIs matching name pattern (e.g., "myapp-*")
  --no-dry-run             Deregister AMIs and delete snapshots (default: dry-run)
  -h, --help               Show this help

Examples:
  # Dry-run: show AMIs that would be deleted
  bash/aws-ami-cleanup.sh --older-than-days 180

  # Delete AMIs older than 1 year matching pattern
  bash/aws-ami-cleanup.sh --name-filter "legacy-*" --older-than-days 365 --no-dry-run

  # Clean up AMIs in specific region
  bash/aws-ami-cleanup.sh --region us-west-2 --older-than-days 90 --no-dry-run

EOF
}

REGION=""
OLDER_THAN_DAYS=90
NAME_FILTER=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --older-than-days) OLDER_THAN_DAYS="$2"; shift 2;;
    --name-filter) NAME_FILTER="$2"; shift 2;;
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

AWS=(aws ec2)
if [[ -n "$REGION" ]]; then
  AWS+=(--region "$REGION")
fi

echo "AMI Cleanup: older-than-days=$OLDER_THAN_DAYS name-filter=${NAME_FILTER:-*} dry-run=$DRY_RUN"

# Get account ID
account_id=$("${AWS[@]}" describe-security-groups --group-names default --query 'SecurityGroups[0].OwnerId' --output text 2>/dev/null || echo "")

if [[ -z "$account_id" ]]; then
  echo "Failed to determine account ID"; exit 1
fi

echo "Account: $account_id"

# Calculate threshold date
now_epoch=$(date +%s)
threshold=$((now_epoch - OLDER_THAN_DAYS * 86400))

# Get all AMIs owned by this account
echo "Fetching AMIs..."
ami_filter="Name=owner-id,Values=$account_id"

if [[ -n "$NAME_FILTER" ]]; then
  amis_json=$("${AWS[@]}" describe-images --owners self --filters "$ami_filter" "Name=name,Values=$NAME_FILTER" --output json 2>/dev/null || echo '{}')
else
  amis_json=$("${AWS[@]}" describe-images --owners self --filters "$ami_filter" --output json 2>/dev/null || echo '{}')
fi

mapfile -t amis < <(echo "$amis_json" | jq -c '.Images[]?')

echo "Found ${#amis[@]} AMI(s) owned by account"

# Get running instances to check AMI usage
echo "Checking AMI usage by EC2 instances..."
instances_json=$("${AWS[@]}" describe-instances --query 'Reservations[].Instances[].[ImageId]' --output json 2>/dev/null || echo '[]')
mapfile -t used_amis < <(echo "$instances_json" | jq -r '.[][]' | sort -u)

# Get launch templates
echo "Checking AMI usage by launch templates..."
lt_json=$("${AWS[@]}" describe-launch-template-versions --query 'LaunchTemplateVersions[].[LaunchTemplateData.ImageId]' --output json 2>/dev/null || echo '[]')
mapfile -t lt_amis < <(echo "$lt_json" | jq -r '.[][]' | grep -v null | sort -u)

# Combine used AMIs
declare -A ami_in_use
for ami in "${used_amis[@]}" "${lt_amis[@]}"; do
  ami_in_use["$ami"]=1
done

declare -a candidates

for ami in "${amis[@]}"; do
  ami_id=$(echo "$ami" | jq -r '.ImageId')
  ami_name=$(echo "$ami" | jq -r '.Name // "unnamed"')
  ami_date=$(echo "$ami" | jq -r '.CreationDate')
  
  # Parse creation date
  ami_epoch=$(date -d "$ami_date" +%s 2>/dev/null || echo 0)
  
  if [[ $ami_epoch -eq 0 ]]; then
    continue
  fi
  
  age_days=$(( (now_epoch - ami_epoch) / 86400 ))
  
  # Check if AMI is old enough and not in use
  if [[ $ami_epoch -lt $threshold ]] && [[ -z "${ami_in_use[$ami_id]:-}" ]]; then
    echo "  CANDIDATE: $ami_id ($ami_name) - age=$age_days days, not in use"
    candidates+=("$ami_id:$ami_name")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo ""
  echo "No AMIs to clean up."
  exit 0
fi

echo ""
echo "Found ${#candidates[@]} AMI(s) to deregister"

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: would deregister the following AMIs:"
  for item in "${candidates[@]}"; do
    ami_id="${item%%:*}"
    ami_name="${item#*:}"
    echo "  - $ami_id ($ami_name)"
  done
else
  for item in "${candidates[@]}"; do
    ami_id="${item%%:*}"
    ami_name="${item#*:}"
    
    echo "Deregistering: $ami_id ($ami_name)"
    
    # Get snapshots associated with this AMI
    snapshots=$(echo "$amis_json" | jq -r ".Images[] | select(.ImageId == \"$ami_id\") | .BlockDeviceMappings[]?.Ebs.SnapshotId // empty")
    
    # Deregister AMI
    "${AWS[@]}" deregister-image --image-id "$ami_id" 2>/dev/null || {
      echo "  Failed to deregister $ami_id"
      continue
    }
    
    # Delete associated snapshots
    if [[ -n "$snapshots" ]]; then
      while read -r snap_id; do
        if [[ -n "$snap_id" && "$snap_id" != "null" ]]; then
          echo "  Deleting snapshot: $snap_id"
          "${AWS[@]}" delete-snapshot --snapshot-id "$snap_id" 2>/dev/null || echo "    Failed to delete $snap_id"
        fi
      done <<< "$snapshots"
    fi
  done
fi

echo ""
echo "Done."
