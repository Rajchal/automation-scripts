#!/usr/bin/env bash
set -euo pipefail

# Create EBS snapshots for volumes matching a tag and rotate old snapshots.
# Usage: aws-ebs-snapshot-rotate.sh -t TAG_KEY=TAG_VALUE -r 7 [--keep-count 3] [--dry-run]

usage(){
  cat <<EOF
Usage: $0 -t TAG_KEY=TAG_VALUE -r RETENTION_DAYS [--keep-count N] [--dry-run]

Creates snapshots for EBS volumes matching a tag and deletes snapshots older than RETENTION_DAYS.
Options:
  -t TAG        Tag filter, e.g. Environment=prod
  -r DAYS       Retention in days (delete snapshots older than this)
  --keep-count N  Keep at least N most recent snapshots per volume (optional)
  --dry-run     Show actions without making changes
  -h            Show this help
EOF
}

DRY_RUN=true
KEEP_COUNT=0
TAG_FILTER=""
RETENTION_DAYS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) TAG_FILTER="$2"; shift 2;;
    -r) RETENTION_DAYS="$2"; shift 2;;
    --keep-count) KEEP_COUNT="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$TAG_FILTER" || "$RETENTION_DAYS" -le 0 ]]; then
  usage; exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not found; please install and configure credentials."; exit 3
fi

echo "Tag filter: $TAG_FILTER";
echo "Retention days: $RETENTION_DAYS";
echo "Keep count: $KEEP_COUNT";
echo "Dry run: $DRY_RUN";

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Find volumes matching tag
VOL_IDS=$(aws ec2 describe-volumes --filters "Name=tag:$TAG_FILTER" --query 'Volumes[].VolumeId' --output text)

if [[ -z "$VOL_IDS" ]]; then
  echo "No volumes found with tag $TAG_FILTER"; exit 0
fi

for vol in $VOL_IDS; do
  echo "Processing volume: $vol"
  description="Snapshot of $vol created_by=aws-ebs-snapshot-rotate at $NOW"
  if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN: aws ec2 create-snapshot --volume-id $vol --description \"$description\""
  else
    snap_id=$(aws ec2 create-snapshot --volume-id "$vol" --description "$description" --query SnapshotId --output text)
    echo "Created snapshot $snap_id"
  fi

  # Rotate: list snapshots for this volume with our description pattern
  snaps=$(aws ec2 describe-snapshots --filters "Name=volume-id,Values=$vol" "Name=description,Values=*aws-ebs-snapshot-rotate*" --query 'Snapshots[*].[SnapshotId,StartTime]' --output text | sort -k2)

  if [[ -z "$snaps" ]]; then
    echo "No snapshots to rotate for $vol"
    continue
  fi

  # delete snapshots older than retention days
  cutoff=$(date -d "-$RETENTION_DAYS days" +%s)
  while read -r sid start; do
    st_epoch=$(date -d "$start" +%s)
    if [[ $st_epoch -lt $cutoff ]]; then
      if [[ $KEEP_COUNT -gt 0 ]]; then
        # count how many snapshots remain (quick check: we'll not delete if total <= KEEP_COUNT)
        total=$(echo "$snaps" | wc -l)
        if [[ $total -le $KEEP_COUNT ]]; then
          echo "Skipping deletion to preserve keep-count ($KEEP_COUNT) for $vol"
          break
        fi
      fi
      if [[ "$DRY_RUN" == true ]]; then
        echo "DRY RUN: aws ec2 delete-snapshot --snapshot-id $sid"
      else
        aws ec2 delete-snapshot --snapshot-id "$sid"
        echo "Deleted snapshot $sid"
      fi
    fi
  done <<< "$snaps"
done

echo "Done."
