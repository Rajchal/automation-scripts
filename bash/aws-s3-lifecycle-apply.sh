#!/usr/bin/env bash
set -euo pipefail

# Detect S3 buckets without lifecycle rules (or missing expiration/transition)
# and optionally apply a safe lifecycle policy. Dry-run by default.
# Usage: aws-s3-lifecycle-apply.sh [--region REGION] [--age-days N] [--transition-days N] [--apply] [--no-dry-run]

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--age-days DAYS] [--transition-days DAYS] [--apply] [--dry-run | --no-dry-run]

Detect buckets that either have no lifecycle configuration or are missing an expiration rule
and show a safe lifecycle policy suggestion. By default the script prints proposed changes
(`--dry-run`). Use `--apply --no-dry-run` to actually put the lifecycle configuration.

Options:
  --region REGION       AWS region for listing buckets (optional; uses AWS default)
  --age-days DAYS       Expiration age in days for objects (default: 365)
  --transition-days N   Transition to STANDARD_IA after N days (default: 30)
  --apply               Include buckets in the apply set (only used if --no-dry-run)
  --dry-run             Only print actions (default)
  --no-dry-run          Perform changes (requires --apply)
  -h, --help            Show this help

Examples:
  # Show suggested lifecycle for buckets missing expiration
  bash/aws-s3-lifecycle-apply.sh --age-days 365 --transition-days 30

  # Apply suggestions (use with caution)
  bash/aws-s3-lifecycle-apply.sh --age-days 365 --transition-days 30 --apply --no-dry-run

EOF
}

REGION=""
AGE_DAYS=365
TRANSITION_DAYS=30
DO_APPLY=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --age-days) AGE_DAYS="$2"; shift 2;;
    --transition-days) TRANSITION_DAYS="$2"; shift 2;;
    --apply) DO_APPLY=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI required; please install and configure credentials."; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required for JSON parsing; please install jq."; exit 3
fi

AWS_BASE=(aws s3api)
if [[ -n "$REGION" ]]; then
  AWS_BASE+=(--region "$REGION")
fi

echo "Listing S3 buckets..."
buckets_json=$(${AWS_BASE[*]} list-buckets --query 'Buckets[].Name' --output json)
mapfile -t buckets < <(echo "$buckets_json" | jq -r '.[]')

if [[ ${#buckets[@]} -eq 0 ]]; then
  echo "No buckets found."; exit 0
fi

echo "Found ${#buckets[@]} buckets; checking lifecycle configuration..."

declare -a suggestions

for b in "${buckets[@]}"; do
  # Check if bucket has lifecycle configuration
  if ${AWS_BASE[*]} get-bucket-lifecycle-configuration --bucket "$b" >/dev/null 2>&1; then
    # Bucket has some lifecycle — check for existence of an expiration rule
    lc=$(${AWS_BASE[*]} get-bucket-lifecycle-configuration --bucket "$b" --output json 2>/dev/null || echo "{}")
    has_expiration=$(echo "$lc" | jq -e '.Rules[]? | select(.Expiration != null) // empty' >/dev/null 2>&1 && echo true || echo false)
    if [[ "$has_expiration" == "true" ]]; then
      echo "OK: $b already has an expiration rule; skipping"
      continue
    else
      echo "Suggest: $b has lifecycle rules but no expiration; propose adding expiration"
    fi
  else
    echo "Suggest: $b has no lifecycle configuration"
  fi

  # Skip buckets that are versioned (require separate handling)
  ver=$(${AWS_BASE[*]} get-bucket-versioning --bucket "$b" --output json 2>/dev/null || echo "{}")
  status=$(echo "$ver" | jq -r '.Status // empty')
  if [[ "$status" == "Enabled" ]]; then
    echo "  Note: $b is versioned — lifecycle rules for versioning require additional rules; skipping suggestion"
    continue
  fi

  # Build suggested lifecycle JSON
  policy=$(cat <<JSON
{
  "Rules": [
    {
      "ID": "auto-lifecycle-expire-${AGE_DAYS}d",
      "Filter": { "Prefix": "" },
      "Status": "Enabled",
      "Transitions": [
        { "Days": $TRANSITION_DAYS, "StorageClass": "STANDARD_IA" }
      ],
      "Expiration": { "Days": $AGE_DAYS }
    }
  ]
}
JSON
)

  suggestions+=("$b")
  echo "--- Proposed lifecycle for $b ---"
  echo "$policy"

  # If apply requested and not dry-run, perform put-bucket-lifecycle-configuration
  if [[ "$DO_APPLY" == true && "$DRY_RUN" == false ]]; then
    tmpfile=$(mktemp)
    echo "$policy" > "$tmpfile"
    echo "Applying lifecycle to $b"
    ${AWS_BASE[*]} put-bucket-lifecycle-configuration --bucket "$b" --lifecycle-configuration file://$tmpfile
    rm -f "$tmpfile"
    echo "Applied lifecycle to $b"
  else
    if [[ "$DO_APPLY" == true && "$DRY_RUN" == true ]]; then
      echo "DRY RUN: would apply lifecycle to $b (re-run with --no-dry-run to apply)"
    else
      echo "Suggestion only: run with --apply --no-dry-run to apply this lifecycle to $b"
    fi
  fi
done

if [[ ${#suggestions[@]} -eq 0 ]]; then
  echo "No buckets required lifecycle suggestions."
else
  echo "\nSummary: proposed lifecycle changes for ${#suggestions[@]} bucket(s):"
  for s in "${suggestions[@]}"; do echo " - $s"; done
fi

echo "Done."
