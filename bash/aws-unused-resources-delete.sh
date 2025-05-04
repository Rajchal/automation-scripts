#!/bin/bash

# Bash script to clean up unused AWS resources
set -e

echo "Cleaning up unused AWS resources..."

# Delete unused EC2 volumes
echo "Deleting unused EC2 volumes..."
aws ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[*].VolumeId" --output text | while read -r VOLUME_ID; do
  echo "Deleting volume: $VOLUME_ID"
  aws ec2 delete-volume --volume-id "$VOLUME_ID"
done

# Delete old snapshots
echo "Deleting snapshots older than 30 days..."
THIRTY_DAYS_AGO=$(date -d "30 days ago" +%Y-%m-%d)
aws ec2 describe-snapshots --owner-ids self --query "Snapshots[?StartTime<='$THIRTY_DAYS_AGO'].SnapshotId" --output text | while read -r SNAPSHOT_ID; do
  echo "Deleting snapshot: $SNAPSHOT_ID"
  aws ec2 delete-snapshot --snapshot-id "$SNAPSHOT_ID"
done

echo "AWS resource cleanup complete!"
