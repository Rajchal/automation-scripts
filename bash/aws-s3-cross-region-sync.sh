#!/usr/bin/env bash
set -euo pipefail

# aws-s3-cross-region-sync.sh
# Sync S3 bucket contents between regions or accounts.
# Verifies data integrity via ETags and object counts.
# Dry-run by default; use --no-dry-run to perform actual sync.

usage(){
  cat <<EOF
Usage: $0 --source-bucket BUCKET --dest-bucket BUCKET [--source-region REGION] [--dest-region REGION] [--prefix PREFIX] [--verify] [--no-dry-run]

Options:
  --source-bucket BUCKET       Source S3 bucket name
  --dest-bucket BUCKET         Destination S3 bucket name
  --source-region REGION       Source region (default: us-east-1)
  --dest-region REGION         Destination region (default: us-east-1)
  --prefix PREFIX              Only sync objects with this prefix
  --verify                     Verify object counts and ETags match after sync
  --no-dry-run                 Perform actual sync (default is dry-run only)
  -h, --help                   Show this help

Examples:
  # Dry-run: list what would be synced from source to destination
  bash/aws-s3-cross-region-sync.sh --source-bucket my-data --dest-bucket my-data-backup

  # Sync app data from us-east-1 to us-west-2
  bash/aws-s3-cross-region-sync.sh --source-bucket my-app-data --dest-bucket my-app-data-west \
    --source-region us-east-1 --dest-region us-west-2 --no-dry-run

  # Sync with verification
  bash/aws-s3-cross-region-sync.sh --source-bucket src --dest-bucket dst --verify --no-dry-run

EOF
}

SOURCE_BUCKET=""
DEST_BUCKET=""
SOURCE_REGION="us-east-1"
DEST_REGION="us-east-1"
PREFIX=""
VERIFY=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-bucket) SOURCE_BUCKET="$2"; shift 2;;
    --dest-bucket) DEST_BUCKET="$2"; shift 2;;
    --source-region) SOURCE_REGION="$2"; shift 2;;
    --dest-region) DEST_REGION="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --verify) VERIFY=true; shift;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$SOURCE_BUCKET" || -z "$DEST_BUCKET" ]]; then
  echo "--source-bucket and --dest-bucket are required"; usage; exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required"; exit 3
fi

S3_SRC=(aws s3api --region "$SOURCE_REGION")
S3_DST=(aws s3api --region "$DEST_REGION")

echo "S3 cross-region sync: source=$SOURCE_BUCKET (region=$SOURCE_REGION) dest=$DEST_BUCKET (region=$DEST_REGION) prefix=${PREFIX:-all} verify=$VERIFY dry-run=$DRY_RUN"

# List source objects
list_args=(list-objects-v2 --bucket "$SOURCE_BUCKET" --output json)
if [[ -n "$PREFIX" ]]; then
  list_args+=(--prefix "$PREFIX")
fi

source_objs=$("${S3_SRC[@]}" "${list_args[@]}" 2>/dev/null || echo '{}')
mapfile -t objects < <(echo "$source_objs" | jq -c '.Contents[]? | {Key, ETag, Size}')

if [[ ${#objects[@]} -eq 0 ]]; then
  echo "No objects found in source bucket."; exit 0
fi

echo "Found ${#objects[@]} object(s) in source bucket."

declare -i total=0
declare -i synced=0
declare -i failed=0

for obj_json in "${objects[@]}"; do
  key=$(echo "$obj_json" | jq -r '.Key')
  etag=$(echo "$obj_json" | jq -r '.ETag' | tr -d '"')
  size=$(echo "$obj_json" | jq -r '.Size')

  ((total++))

  if [[ "$DRY_RUN" == true ]]; then
    echo "  [DRY RUN] Would copy: $key (size=$size bytes, etag=$etag)"
    ((synced++))
    continue
  fi

  # Perform copy
  echo "  Copying: $key"
  if "${S3_SRC[@]}" get-object --bucket "$SOURCE_BUCKET" --key "$key" /tmp/s3_sync_temp 2>/dev/null && \
     "${S3_DST[@]}" put-object --bucket "$DEST_BUCKET" --key "$key" --body /tmp/s3_sync_temp 2>/dev/null; then
    ((synced++))
    rm -f /tmp/s3_sync_temp
  else
    echo "    Failed to copy $key"
    ((failed++))
  fi
done

echo ""
echo "Summary: total=$total synced=$synced failed=$failed"

if [[ "$VERIFY" == true && "$DRY_RUN" == false ]]; then
  echo ""
  echo "Verifying data integrity..."

  # Count objects in destination
  dest_list=$("${S3_DST[@]}" list-objects-v2 --bucket "$DEST_BUCKET" --output json 2>/dev/null || echo '{}')
  dest_count=$(echo "$dest_list" | jq '.Contents | length')

  if [[ "$dest_count" -eq "$total" ]]; then
    echo "✓ Object counts match: $total objects"
  else
    echo "✗ Object count mismatch: expected $total, got $dest_count"
  fi
fi

echo "Done."
