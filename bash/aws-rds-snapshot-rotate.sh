#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 --instance-id <rds-identifier> [--retention DAYS] [--region REGION] [--prefix PREFIX]

Creates a manual DB snapshot for the specified RDS instance and keeps only the newest
N snapshots (per prefix). Requires AWS CLI with permissions for RDS snapshot operations.

Options:
  --instance-id   RDS DB instance identifier (required)
  --retention     Number of snapshots to keep (default: 7)
  --prefix        Snapshot name prefix (default: rds-snap)
  --region        AWS region
  --help          show this message

Example:
  $0 --instance-id mydb --retention 14 --prefix prod
EOF
}

if [[ ${#@} -eq 0 ]]; then usage; exit 1; fi

INSTANCE_ID=""
RETENTION=7
PREFIX="rds-snap"
REGION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2;;
    --retention) RETENTION="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$INSTANCE_ID" ]]; then echo "--instance-id is required"; exit 2; fi

AWS_CLI=(aws)
if [[ -n "$REGION" ]]; then AWS_CLI+=(--region "$REGION"); fi

TS=$(date -u +"%Y%m%dT%H%M%SZ")
SNAP_NAME="${PREFIX}-${INSTANCE_ID}-${TS}"

echo "Creating snapshot $SNAP_NAME for instance $INSTANCE_ID"
${AWS_CLI[*]} rds create-db-snapshot --db-instance-identifier "$INSTANCE_ID" --db-snapshot-identifier "$SNAP_NAME"

echo "Rotating snapshots, keeping latest $RETENTION snapshots with prefix '$PREFIX' for instance $INSTANCE_ID"
mapfile -t SNAP_IDS < <(${AWS_CLI[*]} rds describe-db-snapshots --db-instance-identifier "$INSTANCE_ID" --query "DBSnapshots[?contains(DBSnapshotIdentifier, \\`${PREFIX}-${INSTANCE_ID}-\\`)].{Id:DBSnapshotIdentifier,Time:SnapshotCreateTime}" --output json | jq -r '.|sort_by(.Time)|.[].Id')

TOTAL=${#SNAP_IDS[@]}
if (( TOTAL <= RETENTION )); then
  echo "No snapshots to delete (found $TOTAL, keep $RETENTION)"; exit 0
fi

TO_DELETE=$((TOTAL - RETENTION))
echo "Deleting $TO_DELETE old snapshots"
for ((i=0;i<TO_DELETE;i++)); do
  ID=${SNAP_IDS[i]}
  echo "Deleting $ID"
  ${AWS_CLI[*]} rds delete-db-snapshot --db-snapshot-identifier "$ID" || echo "Warning: failed to delete $ID"
done

echo "Rotation complete."
