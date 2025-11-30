#!/usr/bin/env bash
set -euo pipefail

# Audit NAT Gateways for low BytesProcessed over a time window using CloudWatch.
# Dry-run by default; can tag candidates or delete them if explicitly requested.
# Usage: aws-nat-gateway-idle-auditor.sh [--region REGION] [--days N] [--bytes-threshold N] [--tag] [--delete] [--no-dry-run]

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--bytes-threshold BYTES] [--tag] [--delete] [--no-dry-run]

Options:
  --region REGION         AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N                Evaluate total bytes over the last N days (default: 7)
  --bytes-threshold BYTES Treat NAT gateways with total bytes <= threshold as idle (default: 100000000 = 100MB)
  --tag                   Tag idle NAT gateways with Key=idle_candidate,Value=true (requires --no-dry-run)
  --delete                Delete idle NAT gateways (requires --no-dry-run and caution)
  --dry-run               Default; only print actions
  --no-dry-run            Perform tagging/deletion when requested
  -h, --help              Show this help

Example (dry-run):
  bash/aws-nat-gateway-idle-auditor.sh --days 7 --bytes-threshold 100000000

To tag idle gateways:
  bash/aws-nat-gateway-idle-auditor.sh --days 7 --bytes-threshold 100000000 --tag --no-dry-run

To (dangerous) delete idle gateways:
  bash/aws-nat-gateway-idle-auditor.sh --days 7 --bytes-threshold 100000000 --delete --no-dry-run

EOF
}

REGION=""
DAYS=7
BYTES_THRESHOLD=100000000
DO_TAG=false
DO_DELETE=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --bytes-threshold) BYTES_THRESHOLD="$2"; shift 2;;
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

AWS_EC2=(aws ec2)
CW=(aws cloudwatch)
if [[ -n "$REGION" ]]; then
  AWS_EC2+=(--region "$REGION")
  CW+=(--region "$REGION")
fi

echo "Audit NAT Gateways: days=$DAYS bytes-threshold=$BYTES_THRESHOLD tag=$DO_TAG delete=$DO_DELETE dry-run=$DRY_RUN"

end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_time=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)

echo "Listing NAT Gateways..."
nat_json=$(${AWS_EC2[*]} describe-nat-gateways --query 'NatGateways[?State==`available`].[NatGatewayId,SubnetId,Tags]' --output json)
mapfile -t nat_list < <(echo "$nat_json" | jq -r '.[] | @base64')

if [[ ${#nat_list[@]} -eq 0 ]]; then
  echo "No available NAT Gateways found."; exit 0
fi

declare -a candidates

for b in "${nat_list[@]}"; do
  entry=$(echo "$b" | base64 --decode | jq -r '.')
  nat_id=$(echo "$entry" | jq -r '.[0]')
  subnet=$(echo "$entry" | jq -r '.[1]')
  tags=$(echo "$entry" | jq -c '.[2]')

  # Query CloudWatch BytesProcessed metric sum across the window
  resp=$(${CW[*]} get-metric-statistics --namespace AWS/NATGateway --metric-name BytesProcessed --statistics Sum --period 86400 --start-time "$start_time" --end-time "$end_time" --dimensions Name=NatGatewayId,Value=$nat_id --output json)
  # Sum datapoints
  total=$(echo "$resp" | jq -r '[.Datapoints[].Sum] | add // 0')
  total=${total:-0}
  echo "NAT $nat_id (subnet $subnet): total bytes over ${DAYS}d = $total"
  if [[ $total -le $BYTES_THRESHOLD ]]; then
    candidates+=("$nat_id:$total")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No idle NAT Gateways found (threshold ${BYTES_THRESHOLD} bytes)."; exit 0
fi

echo "\nIdle NAT gateway candidates (total bytes <= ${BYTES_THRESHOLD}):"
for c in "${candidates[@]}"; do
  id=${c%%:*}
  tot=${c#*:}
  echo " - $id (bytes=$tot)"
done

if [[ "$DO_TAG" == false && "$DO_DELETE" == false ]]; then
  echo "\nNo action requested. To tag candidates use --tag --no-dry-run; to delete use --delete --no-dry-run"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: no changes will be made. Re-run with --no-dry-run to perform actions."
  exit 0
fi

for c in "${candidates[@]}"; do
  id=${c%%:*}
  if [[ "$DO_TAG" == true ]]; then
    echo "Tagging $id with idle_candidate=true"
    ${AWS_EC2[*]} create-tags --resources "$id" --tags Key=idle_candidate,Value=true
  fi
  if [[ "$DO_DELETE" == true ]]; then
    echo "Deleting NAT Gateway $id (this will release associated ENIs/EIPs as applicable)"
    ${AWS_EC2[*]} delete-nat-gateway --nat-gateway-id "$id"
  fi
done

echo "Done."
