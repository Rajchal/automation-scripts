#!/usr/bin/env bash
set -euo pipefail

# Audit EC2 network interfaces (ENIs) that are unattached (Status=available).
# Dry-run by default. Tagging or deletion requires explicit flags and --no-dry-run.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--filter-tag KEY=VALUE] [--tag] [--delete] [--no-dry-run]

Options:
  --region REGION           AWS region (uses AWS_DEFAULT_REGION if unset)
  --filter-tag KEY=VALUE    Only include ENIs with this tag (optional)
  --tag                     Tag candidate ENIs with Key=idle_candidate,Value=true
  --delete                  Delete candidate ENIs (dangerous)
  --dry-run                 Default; only print actions
  --no-dry-run              Apply tagging/deletion when requested
  -h, --help                Show this help

Examples:
  # Dry-run: list unattached ENIs
  bash/aws-eni-unattached-auditor.sh

  # Tag candidate ENIs (apply)
  bash/aws-eni-unattached-auditor.sh --tag --no-dry-run

  # Delete candidate ENIs (dangerous)
  bash/aws-eni-unattached-auditor.sh --delete --no-dry-run

EOF
}

REGION=""
FILTER_TAG=""
DO_TAG=false
DO_DELETE=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --filter-tag) FILTER_TAG="$2"; shift 2;;
    --tag) DO_TAG=true; shift;;
    --delete) DO_DELETE=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
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

echo "ENI unattached auditor: filter_tag=${FILTER_TAG:-none} tag=$DO_TAG delete=$DO_DELETE dry-run=$DRY_RUN"

# build filters
filters=("Name=status,Values=available")
if [[ -n "$FILTER_TAG" ]]; then
  # expect KEY=VALUE
  IFS='=' read -r k v <<< "$FILTER_TAG"
  filters+=("Name=tag:$k,Values=$v")
fi

# describe network interfaces that are available (unattached)
cmd=("${EC2[@]}" describe-network-interfaces "--filters" )

# call with filters assembled via aws cli format
resp=$(${EC2[*]} describe-network-interfaces --filters Name=status,Values=available ${FILTER_TAG:+Name=tag:${k},Values=${v}} --output json 2>/dev/null || echo '{}')

mapfile -t nis < <(echo "$resp" | jq -r '.NetworkInterfaces[]? | @base64')

if [[ ${#nis[@]} -eq 0 ]]; then
  echo "No unattached ENIs found (matching filters)."; exit 0
fi

declare -a candidates

for n in "${nis[@]}"; do
  rec=$(echo "$n" | base64 --decode)
  id=$(echo "$rec" | jq -r '.NetworkInterfaceId')
  subnet=$(echo "$rec" | jq -r '.SubnetId')
  vpc=$(echo "$rec" | jq -r '.VpcId')
  az=$(echo "$rec" | jq -r '.AvailabilityZone')
  ip=$(echo "$rec" | jq -r '.PrivateIpAddress // empty')
  desc=$(echo "$rec" | jq -r '.Description // empty')
  tags=$(echo "$rec" | jq -r '.TagSet // [] | map(.Key+"="+.Value) | join(",")')

  echo "- $id subnet=$subnet vpc=$vpc az=$az ip=${ip:-none} desc='${desc}' tags=${tags:-none}"
  candidates+=("$id")
done

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: no tags or deletions performed. Re-run with --no-dry-run and --tag/--delete to act.";
  exit 0
fi

if [[ "$DO_TAG" == true ]]; then
  echo "\nTagging candidate ENIs with Key=idle_candidate,Value=true"
  for id in "${candidates[@]}"; do
    echo "Tagging $id"
    ${EC2[*]} create-tags --resources "$id" --tags Key=idle_candidate,Value=true || echo "Failed to tag $id"
  done
fi

if [[ "$DO_DELETE" == true ]]; then
  echo "\nDeleting candidate ENIs (ensure they are unattached)"
  for id in "${candidates[@]}"; do
    echo "Deleting $id"
    ${EC2[*]} delete-network-interface --network-interface-id "$id" || echo "Failed to delete $id"
  done
fi

echo "Done."
