#!/usr/bin/env bash
set -euo pipefail

# Audit Secrets Manager secrets for missing rotation or long time since last change.
# Dry-run by default. Supports tagging candidates and scheduling deletion with a recovery window.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--age-days N] [--rotation-only] [--tag] [--schedule-delete DAYS] [--no-dry-run]

Options:
  --region REGION        AWS region (uses AWS_DEFAULT_REGION if unset)
  --age-days N           Consider secret stale if last changed older than N days (default: 180)
  --rotation-only        Only report secrets where RotationEnabled is false
  --tag                  Tag candidate secrets with Key=idle_candidate,Value=true
  --schedule-delete DAYS Schedule deletion with recovery window DAYS (requires --no-dry-run)
  --dry-run              Default; only print actions
  --no-dry-run           Apply tagging/schedule-delete when requested
  -h, --help             Show this help

Examples:
  # Dry-run: report secrets with no rotation or last-changed > 180 days
  bash/aws-secretsmanager-stale-secret-auditor.sh --age-days 180

  # Tag candidates
  bash/aws-secretsmanager-stale-secret-auditor.sh --tag --no-dry-run

  # Schedule deletion (recovery window 30 days)
  bash/aws-secretsmanager-stale-secret-auditor.sh --schedule-delete 30 --no-dry-run

EOF
}

REGION=""
AGE_DAYS=180
ROTATION_ONLY=false
DO_TAG=false
SCHEDULE_DELETE=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --age-days) AGE_DAYS="$2"; shift 2;;
    --rotation-only) ROTATION_ONLY=true; shift;;
    --tag) DO_TAG=true; shift;;
    --schedule-delete) SCHEDULE_DELETE="$2"; shift 2;;
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

SM=(aws secretsmanager)
if [[ -n "$REGION" ]]; then
  SM+=(--region "$REGION")
fi

echo "SecretsManager auditor: age-days=$AGE_DAYS rotation-only=$ROTATION_ONLY tag=$DO_TAG schedule-delete=${SCHEDULE_DELETE:-none} dry-run=$DRY_RUN"

cutoff=$(date -u -d "-$AGE_DAYS days" +%s)

secrets_json=$(${SM[*]} list-secrets --max-results 100 --output json 2>/dev/null || echo '{}')
mapfile -t secrets < <(echo "$secrets_json" | jq -r '.SecretList[]? | @base64')

if [[ ${#secrets[@]} -eq 0 ]]; then
  echo "No secrets found (or list-secrets returned empty)."; exit 0
fi

declare -a candidates

for s in "${secrets[@]}"; do
  rec=$(echo "$s" | base64 --decode)
  sid=$(echo "$rec" | jq -r '.ARN // .Name')
  name=$(echo "$rec" | jq -r '.Name')
  rot=$(echo "$rec" | jq -r '.RotationEnabled // false')

  # get last changed date from DescribeSecret (LastChangedDate may be under LastChangedDate)
  desc=$(${SM[*]} describe-secret --secret-id "$sid" --output json 2>/dev/null || echo '{}')
  last_changed=$(echo "$desc" | jq -r '.LastChangedDate // .LastAccessedDate // empty')
  if [[ -z "$last_changed" || "$last_changed" == "null" ]]; then
    # try last changed from versions list
    versions=$(${SM[*]} list-secret-version-ids --secret-id "$sid" --output json 2>/dev/null || echo '{}')
    last_changed=$(echo "$versions" | jq -r '[.Versions[]?.CreatedDate] | max // empty')
  fi

  last_ts=0
  if [[ -n "$last_changed" ]]; then
    # normalize ISO to seconds
    last_ts=$(date -u -d "$last_changed" +%s 2>/dev/null || echo 0)
  fi

  age_ok=0
  if [[ $last_ts -gt 0 && $last_ts -le $cutoff ]]; then
    age_ok=1
  fi

  report=false
  if [[ "$ROTATION_ONLY" == true ]]; then
    if [[ "$rot" == "false" || "$rot" == "0" ]]; then report=true; fi
  else
    # consider secret stale if rotation disabled OR last change older than cutoff
    if [[ "$rot" == "false" || $age_ok -eq 1 ]]; then report=true; fi
  fi

  if [[ "$report" == true ]]; then
    candidates+=("$sid:$name:rotation=$rot:last_changed=${last_changed:-unknown}")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No candidate stale secrets found."; exit 0
fi

echo "\nCandidate stale secrets:"
for c in "${candidates[@]}"; do
  sid=${c%%:*}
  rest=${c#*:}
  name=${rest%%:*}
  meta=${rest#*:}
  echo " - $name ($sid) $meta"
done

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: no tags or deletions scheduled. Re-run with --tag or --schedule-delete <days> and --no-dry-run to act."
  exit 0
fi

if [[ "$DO_TAG" == true ]]; then
  echo "\nTagging candidate secrets with Key=idle_candidate,Value=true"
  for c in "${candidates[@]}"; do
    sid=${c%%:*}
    echo "Tagging $sid"
    ${SM[*]} tag-resource --secret-id "$sid" --tags Key=idle_candidate,Value=true || echo "Failed to tag $sid"
  done
fi

if [[ -n "$SCHEDULE_DELETE" ]]; then
  echo "\nScheduling deletion for candidate secrets with recovery window ${SCHEDULE_DELETE} days"
  for c in "${candidates[@]}"; do
    sid=${c%%:*}
    echo "Scheduling delete for $sid (recovery-window-days=${SCHEDULE_DELETE})"
    ${SM[*]} delete-secret --secret-id "$sid" --recovery-window-in-days "$SCHEDULE_DELETE" || echo "Failed to schedule delete for $sid"
  done
fi

echo "Done."
