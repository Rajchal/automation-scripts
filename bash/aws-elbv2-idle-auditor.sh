#!/usr/bin/env bash
set -euo pipefail

# Audit ELBv2 (ALB/NLB) for low activity using CloudWatch metrics.
# Dry-run by default; can tag or delete candidates when explicitly requested.
# Usage: aws-elbv2-idle-auditor.sh [--region REGION] [--days N] [--req-threshold N] [--bytes-threshold N] [--tag] [--delete] [--no-dry-run]

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--req-threshold N] [--bytes-threshold N] [--tag] [--delete] [--no-dry-run]

Options:
  --region REGION         AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N                Evaluate metric sum over last N days (default: 7)
  --req-threshold N      ALB RequestCount threshold (default: 100)
  --bytes-threshold N    NLB ProcessedBytes threshold (default: 1000000 = 1MB)
  --tag                   Tag idle load balancers with Key=idle_candidate,Value=true (requires --no-dry-run)
  --delete                Delete idle load balancers (requires --no-dry-run and caution)
  --dry-run               Default; only print actions
  --no-dry-run            Perform tagging/deletion when requested
  -h, --help              Show this help

Examples:
  # Dry-run, detect idle ALB/NLB
  bash/aws-elbv2-idle-auditor.sh --days 7 --req-threshold 100 --bytes-threshold 1000000

  # Tag idle load balancers
  bash/aws-elbv2-idle-auditor.sh --days 7 --tag --no-dry-run

  # Dangerous: delete idle load balancers
  bash/aws-elbv2-idle-auditor.sh --days 7 --delete --no-dry-run

EOF
}

REGION=""
DAYS=7
REQ_THRESHOLD=100
BYTES_THRESHOLD=1000000
DO_TAG=false
DO_DELETE=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --req-threshold) REQ_THRESHOLD="$2"; shift 2;;
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

ELB=(aws elbv2)
CW=(aws cloudwatch)
if [[ -n "$REGION" ]]; then
  ELB+=(--region "$REGION")
  CW+=(--region "$REGION")
fi

echo "Audit ELBv2: days=$DAYS req-threshold=$REQ_THRESHOLD bytes-threshold=$BYTES_THRESHOLD tag=$DO_TAG delete=$DO_DELETE dry-run=$DRY_RUN"

end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_time=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)

echo "Listing load balancers..."
lbs_json=$(${ELB[*]} describe-load-balancers --query 'LoadBalancers[].[LoadBalancerArn,LoadBalancerName,Type,Scheme]' --output json)
mapfile -t lb_list < <(echo "$lbs_json" | jq -r '.[] | @base64')

if [[ ${#lb_list[@]} -eq 0 ]]; then
  echo "No load balancers found."; exit 0
fi

declare -a candidates

for e in "${lb_list[@]}"; do
  lb=$(echo "$e" | base64 --decode | jq -r '.')
  arn=$(echo "$lb" | jq -r '.[0]')
  name=$(echo "$lb" | jq -r '.[1]')
  type=$(echo "$lb" | jq -r '.[2]')
  scheme=$(echo "$lb" | jq -r '.[3]')

  if [[ "$type" == "application" ]]; then
    # ALB: use RequestCount
    resp=$(${CW[*]} get-metric-statistics --namespace AWS/ApplicationELB --metric-name RequestCount --statistics Sum --period 86400 --start-time "$start_time" --end-time "$end_time" --dimensions Name=LoadBalancer,Value=${name} --output json 2>/dev/null || echo '{}')
    total=$(echo "$resp" | jq -r '[.Datapoints[].Sum] | add // 0')
    total=${total:-0}
    echo "ALB $name ($arn): total requests over ${DAYS}d = $total"
    if [[ $total -le $REQ_THRESHOLD ]]; then
      candidates+=("$arn:$name:application:$total")
    fi
  elif [[ "$type" == "network" ]]; then
    # NLB: use ProcessedBytes metric
    resp=$(${CW[*]} get-metric-statistics --namespace AWS/NLB --metric-name ProcessedBytes --statistics Sum --period 86400 --start-time "$start_time" --end-time "$end_time" --dimensions Name=LoadBalancer,Value=${arn} --output json 2>/dev/null || echo '{}')
    total=$(echo "$resp" | jq -r '[.Datapoints[].Sum] | add // 0')
    total=${total:-0}
    echo "NLB $name ($arn): total bytes over ${DAYS}d = $total"
    if [[ $total -le $BYTES_THRESHOLD ]]; then
      candidates+=("$arn:$name:network:$total")
    fi
  else
    echo "Skipping LB $name of type $type"
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No idle load balancers found."; exit 0
fi

echo "\nIdle load balancer candidates:"
for c in "${candidates[@]}"; do
  arn=${c%%:*}
  rest=${c#*:}
  name=${rest%%:*}
  type=${rest#*:}
  val=${type#*:}
  # extract type and value properly
  # stored as arn:name:type:val
  val=$(echo "$c" | awk -F: '{print $4}')
  t=$(echo "$c" | awk -F: '{print $3}')
  echo " - $name ($arn) type=$t metric=$val"
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
  arn=${c%%:*}
  name=$(echo "$c" | awk -F: '{print $2}')
  if [[ "$DO_TAG" == true ]]; then
    echo "Tagging load balancer $name ($arn) with idle_candidate=true"
    ${ELB[*]} add-tags --resource-arns "$arn" --tags Key=idle_candidate,Value=true
  fi
  if [[ "$DO_DELETE" == true ]]; then
    echo "Deleting load balancer $name ($arn)"
    ${ELB[*]} delete-load-balancer --load-balancer-arn "$arn"
  fi
done

echo "Done."
