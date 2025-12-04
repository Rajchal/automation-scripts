#!/usr/bin/env bash
set -euo pipefail

# aws-cloudwatch-log-retention-fixer.sh
# Find CloudWatch log groups without retention set and optionally apply a default retention period.
# Reports log groups with infinite retention (no expiration).
# Dry-run by default; use --no-dry-run to apply retention policy.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--retention-days N] [--filter-prefix PREFIX] [--exclude-prefix PREFIX] [--no-dry-run]

Options:
  --region REGION           AWS region (uses AWS_DEFAULT_REGION if unset)
  --retention-days N        Apply N-day retention to log groups without retention (default: 30)
  --filter-prefix PREFIX    Only consider log groups matching this prefix
  --exclude-prefix PREFIX   Skip log groups matching this prefix (e.g. /aws/lambda for system logs)
  --no-dry-run              Apply retention changes (default is dry-run only)
  -h, --help                Show this help

Examples:
  # Dry-run: find all log groups without retention
  bash/aws-cloudwatch-log-retention-fixer.sh

  # Find app log groups and apply 7-day retention
  bash/aws-cloudwatch-log-retention-fixer.sh --filter-prefix /app/ --retention-days 7 --no-dry-run

  # Apply 30-day retention but skip AWS managed logs
  bash/aws-cloudwatch-log-retention-fixer.sh --exclude-prefix '/aws/' --no-dry-run

EOF
}

REGION=""
RETENTION_DAYS=30
FILTER_PREFIX=""
EXCLUDE_PREFIX=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --retention-days) RETENTION_DAYS="$2"; shift 2;;
    --filter-prefix) FILTER_PREFIX="$2"; shift 2;;
    --exclude-prefix) EXCLUDE_PREFIX="$2"; shift 2;;
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

LOGS=(aws logs)
if [[ -n "$REGION" ]]; then
  LOGS+=(--region "$REGION")
fi

echo "CloudWatch log retention fixer: retention-days=$RETENTION_DAYS filter-prefix=${FILTER_PREFIX:-all} exclude-prefix=${EXCLUDE_PREFIX:-none} dry-run=$DRY_RUN"

# Describe all log groups
groups_json=$("${LOGS[@]}" describe-log-groups --output json 2>/dev/null || echo '{}')
mapfile -t groups < <(echo "$groups_json" | jq -c '.logGroups[]?')

if [[ ${#groups[@]} -eq 0 ]]; then
  echo "No log groups found."; exit 0
fi

declare -a candidates

for grp in "${groups[@]}"; do
  name=$(echo "$grp" | jq -r '.logGroupName')
  retention=$(echo "$grp" | jq -r '.retentionInDays // empty')

  # Apply filters
  if [[ -n "$FILTER_PREFIX" && ! "$name" =~ ^$FILTER_PREFIX ]]; then
    continue
  fi
  if [[ -n "$EXCLUDE_PREFIX" && "$name" =~ ^$EXCLUDE_PREFIX ]]; then
    continue
  fi

  # Only consider groups without retention set (infinite retention)
  if [[ -z "$retention" || "$retention" == "null" ]]; then
    echo "Found: $name (no retention set)"
    candidates+=("$name")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No log groups without retention found (matching filters)."; exit 0
fi

echo "\nTotal candidates: ${#candidates[@]}"

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: the following log groups would be updated to $RETENTION_DAYS-day retention (re-run with --no-dry-run to apply):"
  for name in "${candidates[@]}"; do
    echo "  $name"
  done
  exit 0
fi

echo "\nApplying $RETENTION_DAYS-day retention to ${#candidates[@]} log group(s)..."
declare -i success=0
declare -i failed=0

for name in "${candidates[@]}"; do
  if "${LOGS[@]}" put-retention-policy --log-group-name "$name" --retention-in-days "$RETENTION_DAYS" 2>/dev/null; then
    echo "  ✓ $name"
    ((success++)) || true
  else
    echo "  ✗ $name (failed)"
    ((failed++)) || true
  fi
done

echo "\nResults: $success succeeded, $failed failed"
echo "Done."
