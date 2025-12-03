#!/usr/bin/env bash
set -euo pipefail

# Create manual snapshots for ElastiCache replication groups (or clusters) and rotate old manual snapshots.
# Dry-run by default. Use --no-dry-run to perform create/delete actions.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--replication-group RGID] [--keep N] [--no-dry-run]

Options:
  --region REGION        AWS region (uses AWS_DEFAULT_REGION if unset)
  --replication-group ID Only operate on this replication group (optional)
  --keep N               Keep N latest manual snapshots per replication group (default: 7)
  --dry-run              Default; only show actions
  --no-dry-run           Actually create snapshot and delete older ones when requested
  -h, --help             Show this help

Examples:
  # Dry-run for all replication groups, keep last 7 manual snapshots
  bash/aws-elasticache-snapshot-rotate.sh

  # Create snapshot for a specific replication group and keep last 3
  bash/aws-elasticache-snapshot-rotate.sh --replication-group my-rg --keep 3 --no-dry-run

EOF
}

REGION=""
RG=""
KEEP=7
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --replication-group) RG="$2"; shift 2;;
    --keep) KEEP="$2"; shift 2;;
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

EL=(aws elasticache)
if [[ -n "$REGION" ]]; then
  EL+=(--region "$REGION")
fi

echo "ElastiCache snapshot rotate: rg=${RG:-all} keep=$KEEP dry-run=$DRY_RUN"

if [[ -n "$RG" ]]; then
  rgs=("$RG")
else
  rjson=$(${EL[*]} describe-replication-groups --query 'ReplicationGroups[].ReplicationGroupId' --output json 2>/dev/null || echo '[]')
  mapfile -t rgs < <(echo "$rjson" | jq -r '.[]')
fi

if [[ ${#rgs[@]} -eq 0 ]]; then
  echo "No replication groups found."; exit 0
fi

for rgid in "${rgs[@]}"; do
  echo "Processing replication group: $rgid"

  timestamp=$(date -u +%Y%m%d%H%M%S)
  snap_name="${rgid}-manual-${timestamp}"

  echo "  Manual snapshot name: $snap_name"

  if [[ "$DRY_RUN" == true ]]; then
    echo "  DRY RUN: would create snapshot: ${snap_name} for replication group ${rgid}"
  else
    echo "  Creating snapshot ${snap_name} for ${rgid}"
    ${EL[*]} create-snapshot --replication-group-id "$rgid" --snapshot-name "$snap_name" || echo "    create-snapshot failed for $rgid"
  fi

  # List manual snapshots for this replication group, sorted newest->oldest
  snaps_json=$(${EL[*]} describe-snapshots --replication-group-id "$rgid" --output json 2>/dev/null || echo '[]')
  mapfile -t snaps < <(echo "$snaps_json" | jq -r '.Snapshots[]? | select(.SnapshotSource=="manual") | [.SnapshotName, .SnapshotCreateTime] | @base64')

  if [[ ${#snaps[@]} -le $KEEP ]]; then
    echo "  Only ${#snaps[@]} manual snapshots found (<= keep=$KEEP); nothing to delete."
    continue
  fi

  # build array of snapshots sorted by create time ascending (oldest first)
  declare -a sorted
  for s in "${snaps[@]}"; do
    rec=$(echo "$s" | base64 --decode)
    name=$(echo "$rec" | jq -r '.[0]')
    t=$(echo "$rec" | jq -r '.[1]')
    sorted+=("$t:$name")
  done
  IFS=$'\n' sorted=($(printf "%s\n" "${sorted[@]}" | sort))
  unset IFS

  # number to delete = total - KEEP
  total=${#sorted[@]}
  del_count=$((total - KEEP))
  echo "  Found $total manual snapshots; will delete $del_count oldest ones when not dry-run"

  idx=0
  for entry in "${sorted[@]}"; do
    if [[ $idx -ge $del_count ]]; then break; fi
    snap_to_delete=${entry#*:}
    echo "    Old snapshot to delete: $snap_to_delete"
    if [[ "$DRY_RUN" == false ]]; then
      echo "    Deleting snapshot $snap_to_delete"
      ${EL[*]} delete-snapshot --snapshot-name "$snap_to_delete" || echo "      Failed to delete $snap_to_delete"
    fi
    idx=$((idx+1))
  done
done

echo "Done."
