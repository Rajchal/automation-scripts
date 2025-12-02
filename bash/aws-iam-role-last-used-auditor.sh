#!/usr/bin/env bash
set -euo pipefail

# Audit IAM roles for lack of AssumeRole activity (CloudTrail lookup) in a lookback window.
# Dry-run by default. Tagging requires --tag --no-dry-run.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--tag] [--no-dry-run]

Options:
  --region REGION    AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N           Lookback window in days for CloudTrail events (default: 90)
  --tag              Tag candidate roles with Key=idle_candidate,Value=true
  --dry-run          Default; only print actions
  --no-dry-run       Apply tagging when requested
  -h, --help         Show this help

Examples:
  # Dry-run: report roles with no AssumeRole events in last 90 days
  bash/aws-iam-role-last-used-auditor.sh --days 90

  # Tag candidates (apply)
  bash/aws-iam-role-last-used-auditor.sh --tag --no-dry-run

Notes:
  - This script uses CloudTrail lookup-events to find `AssumeRole` events referencing role ARNs.
  - CloudTrail must be enabled and retain events for the lookback window for accurate results.
EOF
}

REGION=""
DAYS=90
DO_TAG=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --tag) DO_TAG=true; shift;;
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

CT=(aws cloudtrail)
IAM=(aws iam)
if [[ -n "$REGION" ]]; then
  CT+=(--region "$REGION")
  IAM+=(--region "$REGION")
fi

echo "IAM role last-used auditor: days=$DAYS tag=$DO_TAG dry-run=$DRY_RUN"

end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_time=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)

echo "Listing IAM roles..."
roles_json=$(${IAM[*]} list-roles --output json 2>/dev/null || echo '{}')
mapfile -t roles < <(echo "$roles_json" | jq -r '.Roles[]? | @base64')

if [[ ${#roles[@]} -eq 0 ]]; then
  echo "No IAM roles found."; exit 0
fi

declare -a candidates

for r in "${roles[@]}"; do
  rec=$(echo "$r" | base64 --decode)
  role_name=$(echo "$rec" | jq -r '.RoleName')
  role_arn=$(echo "$rec" | jq -r '.Arn')
  echo "Checking role $role_name ($role_arn)"

  # Search CloudTrail for AssumeRole events referencing the role ARN
  # Lookup by ResourceName attribute with the ARN is best-effort; older events may not include it.
  events=$(${CT[*]} lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue="$role_arn" --start-time "$start_time" --end-time "$end_time" --max-results 50 --output json 2>/dev/null || echo '{}')
  count=$(echo "$events" | jq -r '.Events | length // 0')

  # As a fallback, search for AssumeRole events and grep the event/CloudTrailEvent for the role ARN
  if [[ "$count" -eq 0 ]]; then
    events2=$(${CT[*]} lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole --start-time "$start_time" --end-time "$end_time" --max-results 50 --output json 2>/dev/null || echo '{}')
    found=$(echo "$events2" | jq -r --arg arn "$role_arn" '.Events[]?.CloudTrailEvent | select(index($arn)) | length' 2>/dev/null || echo '')
    if [[ -n "$found" ]]; then
      count=$(echo "$events2" | jq -r '.Events | map(select(.CloudTrailEvent | contains($arn))) | length' --arg arn "$role_arn" 2>/dev/null || 0)
    fi
  fi

  if [[ $count -eq 0 ]]; then
    candidates+=("$role_name:$role_arn")
  else
    echo "  found $count AssumeRole events in the window"
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No roles without AssumeRole events in the last ${DAYS} days detected."; exit 0
fi

echo "\nCandidate unused roles (no AssumeRole events found in window):"
for c in "${candidates[@]}"; do
  name=${c%%:*}
  arn=${c#*:}
  echo " - $name ($arn)"
done

if [[ "$DO_TAG" == false ]]; then
  echo "\nNo action requested. To tag these roles re-run with --tag --no-dry-run"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: would tag the candidate roles with Key=idle_candidate,Value=true. Re-run with --no-dry-run to apply."
  exit 0
fi

echo "Tagging candidate roles..."
for c in "${candidates[@]}"; do
  name=${c%%:*}
  echo "Tagging role $name"
  ${IAM[*]} tag-role --role-name "$name" --tags Key=idle_candidate,Value=true || echo "Failed to tag $name"
done

echo "Done."
