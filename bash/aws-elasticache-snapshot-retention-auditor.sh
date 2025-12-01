#!/usr/bin/env bash
set -euo pipefail

# Audit ElastiCache replication groups for automatic snapshot retention settings
# and list old manual snapshots. Dry-run by default; setting retention requires
# explicit --set-retention <days> with --no-dry-run.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--age-days N] [--set-retention DAYS] [--no-dry-run]

Options:
  --region REGION         AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N               Lookback window in days to inspect automatic snapshot retention (default: 7)
  --age-days N           Report manual snapshots older than this (default: 30)
  --set-retention DAYS   Propose setting automatic snapshot retention to DAYS for candidates
  --dry-run              Default; only print actions
  --no-dry-run           Apply requested changes (when --set-retention provided)
  -h, --help             Show this help

Examples:
  # Dry-run: list replication groups with low/zero automatic retention and manual snapshots older than 30d
  bash/aws-elasticache-snapshot-retention-auditor.sh --age-days 30

  # To set retention to 7 days for candidates (requires --no-dry-run)
  bash/aws-elasticache-snapshot-retention-auditor.sh --set-retention 7 --no-dry-run

EOF
}

REGION=""
DAYS=7
AGE_DAYS=30
SET_RETENTION=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --age-days) AGE_DAYS="$2"; shift 2;;
    --set-retention) SET_RETENTION="$2"; shift 2;;
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

echo "ElastiCache snapshot-retention auditor: lookback=${DAYS}d manual-snapshot-age>${AGE_DAYS}d set_retention=${SET_RETENTION:-none} dry-run=${DRY_RUN}"

echo "Listing replication groups..."
rg_json=$(${EL[*]} describe-replication-groups --output json 2>/dev/null || echo '{}')
mapfile -t rgs < <(echo "$rg_json" | jq -r '.ReplicationGroups[]? | @base64')

declare -a candidates

for entry in "${rgs[@]}"; do
  rec=$(echo "$entry" | base64 --decode)
  rgid=$(echo "$rec" | jq -r '.ReplicationGroupId')
  snapshot_retention=$(echo "$rec" | jq -r '.SnapshotRetentionLimit // empty')
  primary_id=$(echo "$rec" | jq -r '.NodeGroups[0].PrimaryEndpoint.Address // empty' 2>/dev/null || echo '')

  if [[ -z "$snapshot_retention" || "$snapshot_retention" == "null" || "$snapshot_retention" -le 0 2>/dev/null ]]; then
    candidates+=("$rgid:$snapshot_retention:$primary_id")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No replication groups with zero or missing automatic snapshot retention found.";
else
  echo "Replication groups missing/zero automatic snapshot retention:"
  for c in "${candidates[@]}"; do
    rgid=${c%%:*}
    rest=${c#*:}
    retention=${rest%%:*}
    host=${rest#*:}
    echo " - $rgid retention=${retention:-unset} primary_host=${host:-unknown}"
  done
fi

# List manual snapshots older than AGE_DAYS
echo "\nListing manual snapshots older than ${AGE_DAYS} days..."
cutoff=$(date -u -d "-$AGE_DAYS days" +%Y-%m-%dT%H:%M:%SZ)
snap_json=$(${EL[*]} describe-snapshots --snapshot-type manual --output json 2>/dev/null || echo '{}')
mapfile -t snaps < <(echo "$snap_json" | jq -r '.Snapshots[]? | @base64')

declare -a old_snaps
for s in "${snaps[@]}"; do
  rec=$(echo "$s" | base64 --decode)
  snap_id=$(echo "$rec" | jq -r '.SnapshotName')
  created=$(echo "$rec" | jq -r '.SnapshotCreateTime')
  rgid=$(echo "$rec" | jq -r '.ReplicationGroupId // empty')
  if [[ -z "$created" || "$created" == "null" ]]; then
    continue
  fi
  if [[ "$(date -d "$created" +%s)" -le "$(date -d "$cutoff" +%s)" ]]; then
    old_snaps+=("$snap_id:$rgid:$created")
  fi
done

if [[ ${#old_snaps[@]} -eq 0 ]]; then
  echo "No manual snapshots older than ${AGE_DAYS} days found."
else
  echo "Manual snapshots older than ${AGE_DAYS} days:"
  for s in "${old_snaps[@]}"; do
    sid=${s%%:*}
    rest=${s#*:}
    rgid=${rest%%:*}
    created=${rest#*:}
    echo " - $sid (rg=$rgid) created=$created"
  done
fi

if [[ -z "$SET_RETENTION" ]]; then
  echo "\nNo retention change requested. To set automatic snapshot retention re-run with --set-retention <days> --no-dry-run"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: would set automatic snapshot retention to $SET_RETENTION for the replication groups listed above. Re-run with --no-dry-run to apply."
  exit 0
fi

echo "Applying automatic snapshot retention=${SET_RETENTION} to candidates..."
for c in "${candidates[@]}"; do
  rgid=${c%%:*}
  echo "Modifying $rgid -> snapshot retention $SET_RETENTION"
  ${EL[*]} modify-replication-group --replication-group-id "$rgid" --snapshot-retention-limit "$SET_RETENTION" --apply-immediately || echo "Failed to modify $rgid"
done

echo "Done."
