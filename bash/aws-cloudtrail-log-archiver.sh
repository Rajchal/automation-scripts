#!/usr/bin/env bash
set -euo pipefail

# CloudTrail log archiver
# - Lists CloudTrail trails and their S3 buckets
# - Finds objects older than N days
# - Optional: copy older logs to an archive bucket (--archive-bucket)
# - Optional: set a basic lifecycle expiration on source buckets (--set-lifecycle DAYS)
# Dry-run by default; use --no-dry-run to perform actions

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--archive-bucket BUCKET] [--copy] [--set-lifecycle DAYS] [--no-dry-run]

Options:
  --region REGION           AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N                 Consider objects older than N days (default: 90)
  --archive-bucket BUCKET  S3 bucket to copy old logs into
  --copy                   Copy old logs to archive bucket (requires --archive-bucket)
  --set-lifecycle DAYS     Apply lifecycle expiration to source buckets (expire after DAYS)
  --no-dry-run             Apply changes instead of dry-run
  -h, --help               Show this help

Examples:
  # Dry-run: list CloudTrail buckets and old objects
  bash/aws-cloudtrail-log-archiver.sh --days 180

  # Copy logs older than 365 days to archive-bucket and apply lifecycle
  bash/aws-cloudtrail-log-archiver.sh --days 365 --archive-bucket my-archive-bucket --copy --set-lifecycle 400 --no-dry-run

EOF
}

REGION=""
DAYS=90
ARCHIVE_BUCKET=""
DO_COPY=false
DO_LIFECYCLE_DAYS=0
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --archive-bucket) ARCHIVE_BUCKET="$2"; shift 2;;
    --copy) DO_COPY=true; shift;;
    --set-lifecycle) DO_LIFECYCLE_DAYS="$2"; shift 2;;
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

AWS=(aws)
if [[ -n "$REGION" ]]; then
  AWS+=(--region "$REGION")
fi

echo "CloudTrail archiver: days=$DAYS archive_bucket=${ARCHIVE_BUCKET:-none} copy=$DO_COPY set-lifecycle=$DO_LIFECYCLE_DAYS dry-run=$DRY_RUN"

now_epoch=$(date +%s)
threshold=$((now_epoch - DAYS*24*3600))

# collect trails
trails_json=$("${AWS[@]}" cloudtrail describe-trails --output json 2>/dev/null || echo '{}')
mapfile -t trails < <(echo "$trails_json" | jq -c '.trailList[]?')

if [[ ${#trails[@]} -eq 0 ]]; then
  echo "No CloudTrail trails found."; exit 0
fi

for t in "${trails[@]}"; do
  name=$(echo "$t" | jq -r '.Name // empty')
  bucket=$(echo "$t" | jq -r '.S3BucketName // empty')
  prefix=$(echo "$t" | jq -r '.S3KeyPrefix // empty')
  region=$(echo "$t" | jq -r '.HomeRegion // empty')

  echo "\nTrail: ${name:-(unnamed)} region=${region:-default} bucket=${bucket:-(none)} prefix=${prefix:-(none)}"
  if [[ -z "$bucket" ]]; then
    echo "  No S3 bucket configured for this trail, skipping."; continue
  fi

  # list objects under prefix (if present) or whole bucket
  list_args=(s3api list-objects-v2 --bucket "$bucket" --output json)
  if [[ -n "$prefix" ]]; then
    list_args+=(--prefix "$prefix")
  fi

  objs_json=$("${AWS[@]}" "${list_args[@]}" 2>/dev/null || echo '{}')
  mapfile -t oldobjs < <(echo "$objs_json" | jq -r '.Contents[]? | "\(.Key)\t\(.LastModified)"' | while IFS=$'\t' read -r key lm; do
    # convert LastModified to epoch
    epoch=$(date -d "$lm" +%s 2>/dev/null || echo 0)
    if [[ $epoch -gt 0 && $epoch -lt $threshold ]]; then
      echo "$key"
    fi
  done)

  if [[ ${#oldobjs[@]} -eq 0 ]]; then
    echo "  No objects older than ${DAYS} days found in s3://${bucket}/${prefix:-}"; continue
  fi

  echo "  Found ${#oldobjs[@]} object(s) older than ${DAYS} days in s3://${bucket}/${prefix:-}"

  if [[ "$DO_COPY" == true ]]; then
    if [[ -z "$ARCHIVE_BUCKET" ]]; then
      echo "  --copy requested but --archive-bucket not provided; skipping copy.";
    else
      for key in "${oldobjs[@]}"; do
        src="s3://${bucket}/${key}"
        dst="s3://${ARCHIVE_BUCKET}/${key}"
        if [[ "$DRY_RUN" == true ]]; then
          echo "  DRY RUN: would copy $src -> $dst"
        else
          echo "  Copying $src -> $dst"
          "${AWS[@]}" s3 cp "$src" "$dst" --only-show-errors || echo "    Failed to copy $key"
        fi
      done
    fi
  fi

  if [[ "$DO_LIFECYCLE_DAYS" -gt 0 ]]; then
    lifecycle=$(cat <<EOF
{
  "Rules": [
    {
      "ID": "cloudtrail-archiver-expire-${DO_LIFECYCLE_DAYS}",
      "Status": "Enabled",
      "Filter": {"Prefix":"${prefix}"},
      "Expiration": {"Days": ${DO_LIFECYCLE_DAYS}}
    }
  ]
}
EOF
)
    if [[ "$DRY_RUN" == true ]]; then
      echo "  DRY RUN: would apply lifecycle to bucket $bucket: expire after ${DO_LIFECYCLE_DAYS} days"
    else
      echo "  Applying lifecycle to bucket $bucket (expire ${DO_LIFECYCLE_DAYS} days)"
      tmpf=$(mktemp)
      echo "$lifecycle" > "$tmpf"
      "${AWS[@]}" s3api put-bucket-lifecycle-configuration --bucket "$bucket" --lifecycle-configuration file://"$tmpf" || echo "    Failed to set lifecycle on $bucket"
      rm -f "$tmpf"
    fi
  fi
done

echo "\nDone."
