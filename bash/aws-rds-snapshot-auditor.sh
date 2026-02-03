#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-rds-snapshot-auditor.log"
REPORT_FILE="/tmp/rds-snapshot-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
SNAPSHOT_AGE_DAYS="${RDS_SNAPSHOT_AGE_DAYS:-7}"
MAX_INSTANCES="${RDS_MAX_INSTANCES:-200}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "RDS Snapshot Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Snapshot age threshold (days): $SNAPSHOT_AGE_DAYS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

days_since() {
  # arg: ISO date
  if [ -z "$1" ]; then
    echo 99999
    return
  fi
  secs=$(date -d "$1" +%s 2>/dev/null || echo 0)
  if [ "$secs" -eq 0 ]; then
    echo 99999
    return
  fi
  echo $(( ( $(date +%s) - secs ) / 86400 ))
}

check_instance_snapshots() {
  local dbi="$1"
  # most recent manual or automated snapshot for this instance
  snaps=$(aws rds describe-db-snapshots --db-instance-identifier "$dbi" --max-records 50 --region "$REGION" --output json 2>/dev/null || echo '{"DBSnapshots":[]}')
  latest=$(echo "$snaps" | jq -r '[.DBSnapshots[]? | {SnapshotType:.SnapshotType, SnapshotCreateTime:.SnapshotCreateTime}] | sort_by(.SnapshotCreateTime) | last | .SnapshotCreateTime // empty')
  if [ -z "$latest" ]; then
    echo "Instance $dbi: NO snapshots found" >> "$REPORT_FILE"
    send_slack_alert "RDS Alert: Instance $dbi has no snapshots"
    return
  fi
  age=$(days_since "$latest")
  echo "Instance $dbi: latest snapshot $latest ($age days)" >> "$REPORT_FILE"
  if [ "$age" -ge "$SNAPSHOT_AGE_DAYS" ]; then
    send_slack_alert "RDS Alert: Instance $dbi latest snapshot is $age days old (threshold $SNAPSHOT_AGE_DAYS)"
  fi
}

check_cluster_snapshots() {
  local cid="$1"
  snaps=$(aws rds describe-db-cluster-snapshots --db-cluster-identifier "$cid" --max-records 50 --region "$REGION" --output json 2>/dev/null || echo '{"DBClusterSnapshots":[]}')
  latest=$(echo "$snaps" | jq -r '[.DBClusterSnapshots[]? | {SnapshotType:.SnapshotType, SnapshotCreateTime:.SnapshotCreateTime}] | sort_by(.SnapshotCreateTime) | last | .SnapshotCreateTime // empty')
  if [ -z "$latest" ]; then
    echo "Cluster $cid: NO snapshots found" >> "$REPORT_FILE"
    send_slack_alert "RDS Alert: Cluster $cid has no snapshots"
    return
  fi
  age=$(days_since "$latest")
  echo "Cluster $cid: latest snapshot $latest ($age days)" >> "$REPORT_FILE"
  if [ "$age" -ge "$SNAPSHOT_AGE_DAYS" ]; then
    send_slack_alert "RDS Alert: Cluster $cid latest snapshot is $age days old (threshold $SNAPSHOT_AGE_DAYS)"
  fi
}

main() {
  write_header

  # Check DB instances
  instances_json=$(aws rds describe-db-instances --max-records "$MAX_INSTANCES" --region "$REGION" --output json 2>/dev/null || echo '{"DBInstances":[]}')
  instances=$(echo "$instances_json" | jq -r '.DBInstances[]?.DBInstanceIdentifier')
  if [ -n "$instances" ]; then
    echo "Checking DB instances snapshots:" >> "$REPORT_FILE"
    for i in $instances; do
      check_instance_snapshots "$i"
    done
    echo "" >> "$REPORT_FILE"
  fi

  # Check DB clusters (Aurora)
  clusters_json=$(aws rds describe-db-clusters --region "$REGION" --output json 2>/dev/null || echo '{"DBClusters":[]}')
  clusters=$(echo "$clusters_json" | jq -r '.DBClusters[]?.DBClusterIdentifier')
  if [ -n "$clusters" ]; then
    echo "Checking DB cluster snapshots:" >> "$REPORT_FILE"
    for c in $clusters; do
      check_cluster_snapshots "$c"
    done
    echo "" >> "$REPORT_FILE"
  fi

  log_message "RDS snapshot audit written to $REPORT_FILE"
}

main "$@"
