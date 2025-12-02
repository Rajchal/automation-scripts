#!/usr/bin/env bash
set -euo pipefail

# Audit S3 buckets for emptiness or staleness (last modified object older than threshold).
# Dry-run by default. Tagging or deletion requires --no-dry-run.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--age-days N] [--check-empty] [--tag] [--delete-empty] [--no-dry-run]

Options:
  --region REGION       AWS region (uses AWS_DEFAULT_REGION if unset)
  --age-days N          Consider bucket stale if last object modified older than N days (default: 365)
  --check-empty         Include empty buckets in report (default: true)
  --tag                 Tag candidate buckets with Key=idle_candidate,Value=true
  --delete-empty        Delete empty buckets (dangerous)
  --dry-run             Default; only print actions
  --no-dry-run          Apply tagging/deletion when requested
  -h, --help            Show this help

Examples:
  # Dry-run: report buckets with no objects or last-modified > 365 days
  bash/aws-s3-unused-bucket-auditor.sh --age-days 365

  # To tag candidates (requires --no-dry-run)
  bash/aws-s3-unused-bucket-auditor.sh --tag --no-dry-run

  # To delete empty buckets (requires --no-dry-run)
  bash/aws-s3-unused-bucket-auditor.sh --delete-empty --no-dry-run

EOF
}

REGION=""
AGE_DAYS=365
CHECK_EMPTY=true
DO_TAG=false
DO_DELETE_EMPTY=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --age-days) AGE_DAYS="$2"; shift 2;;
    --check-empty) CHECK_EMPTY=true; shift;;
    --tag) DO_TAG=true; shift;;
    --delete-empty) DO_DELETE_EMPTY=true; shift;;
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

S3=(aws s3api)
if [[ -n "$REGION" ]]; then
  S3+=(--region "$REGION")
fi

echo "S3 auditor: age-days=$AGE_DAYS check-empty=$CHECK_EMPTY tag=$DO_TAG delete-empty=$DO_DELETE_EMPTY dry-run=$DRY_RUN"

cutoff=$(date -u -d "-$AGE_DAYS days" +%s)

buckets_json=$(${S3[*]} list-buckets --query 'Buckets[]' --output json 2>/dev/null || echo '[]')
mapfile -t buckets < <(echo "$buckets_json" | jq -r '.[]? | @base64')

if [[ ${#buckets[@]} -eq 0 ]]; then
  echo "No buckets found."; exit 0
fi

declare -a empty_buckets
declare -a stale_buckets

for b in "${buckets[@]}"; do
  rec=$(echo "$b" | base64 --decode)
  name=$(echo "$rec" | jq -r '.Name')
  # Check if bucket has at least one object (efficient: request 1 key)
  objs=$({ ${S3[*]} list-objects-v2 --bucket "$name" --max-items 1 --query 'Contents[0].LastModified' --output text 2>/dev/null || echo 'None'; } )
  if [[ "$objs" == "None" || "$objs" == "" ]]; then
    empty_buckets+=("$name")
    continue
  fi

  # If not empty: find most recent LastModified (may be expensive on huge buckets)
  last_mod=$( ${S3[*]} list-objects-v2 --bucket "$name" --query 'Contents[].LastModified' --output text 2>/dev/null | tr '\t' '\n' | sort -r | head -n1 || echo '' )
  if [[ -z "$last_mod" ]]; then
    empty_buckets+=("$name"); continue
  fi
  last_ts=$(date -u -d "$last_mod" +%s)
  if [[ $last_ts -le $cutoff ]]; then
    stale_buckets+=("$name:$last_mod")
  fi
done

if [[ ${#empty_buckets[@]} -eq 0 && ${#stale_buckets[@]} -eq 0 ]]; then
  echo "No empty or stale buckets found."; exit 0
fi

if [[ ${#empty_buckets[@]} -gt 0 ]]; then
  echo "Empty buckets:";
  for n in "${empty_buckets[@]}"; do
    echo " - $n"
  done
fi

if [[ ${#stale_buckets[@]} -gt 0 ]]; then
  echo "\nStale buckets (last object modified):"
  for s in "${stale_buckets[@]}"; do
    name=${s%%:*}
    lm=${s#*:}
    echo " - $name last_modified=$lm"
  done
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: no tags or deletions performed. Re-run with --no-dry-run and --tag/--delete-empty to act."
  exit 0
fi

if [[ "$DO_TAG" == true ]]; then
  echo "\nTagging buckets with Key=idle_candidate,Value=true"
  for n in "${empty_buckets[@]}"; do
    echo "Tagging $n"
    aws s3api put-bucket-tagging --bucket "$n" --tagging '{"TagSet":[{"Key":"idle_candidate","Value":"true"}]}' || echo "Failed to tag $n"
  done
  for s in "${stale_buckets[@]}"; do
    name=${s%%:*}
    echo "Tagging $name"
    aws s3api put-bucket-tagging --bucket "$name" --tagging '{"TagSet":[{"Key":"idle_candidate","Value":"true"}]}' || echo "Failed to tag $name"
  done
fi

if [[ "$DO_DELETE_EMPTY" == true ]]; then
  echo "\nDeleting empty buckets"
  for n in "${empty_buckets[@]}"; do
    echo "Deleting $n"
    aws s3api delete-bucket --bucket "$n" || echo "Failed to delete $n"
  done
fi

echo "Done."
