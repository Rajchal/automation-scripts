#!/usr/bin/env bash
set -euo pipefail

# IAM access key rotator
# Dry-run by default. Use --no-dry-run to perform creation/deactivation.
# By default operate on a single user via --user; use --all to process all users (careful).

usage(){
  cat <<EOF
Usage: $0 [--user USERNAME | --all] [--days N] [--deactivate-old] [--no-dry-run]

Options:
  --user USERNAME       Rotate keys for a specific IAM user
  --all                 Operate on all IAM users (dangerous)
  --days N              Consider keys older than N days (default: 90)
  --deactivate-old      Deactivate old keys after creating new ones
  --no-dry-run          Actually create keys / deactivate old keys
  -h, --help            Show this help

Notes:
  - This script will print newly created AccessKeyId and SecretAccessKey to stdout
    when run without --dry-run. Store them securely; the secret is only shown once.
  - The script does not automatically update applications that use keys.
  - Use with care in production.
EOF
}

USER=""
ALL=false
DAYS=90
DEACTIVATE_OLD=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER="$2"; shift 2;;
    --all) ALL=true; shift;;
    --days) DAYS="$2"; shift 2;;
    --deactivate-old) DEACTIVATE_OLD=true; shift;;
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

if [[ -z "$USER" && "$ALL" == false ]]; then
  echo "Either --user or --all is required."; usage; exit 2
fi

now_epoch=$(date +%s)
threshold=$((now_epoch - DAYS*24*3600))

process_user(){
  local u=$1
  echo "\nProcessing user: $u"
  keys_json=$(aws iam list-access-keys --user-name "$u" --output json 2>/dev/null || echo '{}')
  mapfile -t keys < <(echo "$keys_json" | jq -c '.AccessKeyMetadata[]?')
  if [[ ${#keys[@]} -eq 0 ]]; then
    echo "  No access keys for $u"; return
  fi

  declare -a candidates
  for k in "${keys[@]}"; do
    akid=$(echo "$k" | jq -r '.AccessKeyId')
    create_date=$(echo "$k" | jq -r '.CreateDate')
    create_epoch=0
    if [[ -n "$create_date" && "$create_date" != "null" ]]; then
      create_epoch=$(date -d "$create_date" +%s 2>/dev/null || echo 0)
    fi

    last_used_json=$(aws iam get-access-key-last-used --access-key-id "$akid" --output json 2>/dev/null || echo '{}')
    last_used_date=$(echo "$last_used_json" | jq -r '.AccessKeyLastUsed.LastUsedDate // empty')
    last_used_epoch=0
    if [[ -n "$last_used_date" ]]; then
      last_used_epoch=$(date -d "$last_used_date" +%s 2>/dev/null || echo 0)
    fi

    reason=""
    if [[ $create_epoch -gt 0 && $create_epoch -lt $threshold ]]; then
      reason="old"
    fi
    if [[ $last_used_epoch -gt 0 && $last_used_epoch -lt $threshold ]]; then
      reason="unused"
    fi
    if [[ $last_used_epoch -eq 0 ]]; then
      # never used
      reason="never-used"
    fi

    if [[ -n "$reason" ]]; then
      echo "  Candidate: $akid (created=$create_date last_used=${last_used_date:-never}) reason=$reason"
      candidates+=("$akid")
    fi
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "  No candidate keys for rotation for $u"; return
  fi

  echo "  Found ${#candidates[@]} candidate key(s) for $u"

  if [[ "$DRY_RUN" == true ]]; then
    echo "  DRY RUN: would create a new key for $u and${DEACTIVATE_OLD:+ deactivate old keys}"; return
  fi

  # create a new access key
  echo "  Creating new access key for $u"
  create_out=$(aws iam create-access-key --user-name "$u" --output json)
  new_id=$(echo "$create_out" | jq -r '.AccessKey.AccessKeyId')
  new_secret=$(echo "$create_out" | jq -r '.AccessKey.SecretAccessKey')
  echo "  NEW_ACCESS_KEY_ID=$new_id"
  echo "  NEW_SECRET_ACCESS_KEY=$new_secret"
  echo "  Please store the secret securely; it will not be retrievable later."

  if [[ "$DEACTIVATE_OLD" == true ]]; then
    for old in "${candidates[@]}"; do
      if [[ "$old" == "$new_id" ]]; then
        continue
      fi
      echo "  Deactivating old key $old for $u"
      aws iam update-access-key --user-name "$u" --access-key-id "$old" --status Inactive || echo "    Failed to deactivate $old"
    done
  fi
}

if [[ "$ALL" == true ]]; then
  users_json=$(aws iam list-users --output json 2>/dev/null || echo '{}')
  mapfile -t users < <(echo "$users_json" | jq -r '.Users[]?.UserName')
else
  users=("$USER")
fi

for u in "${users[@]}"; do
  process_user "$u"
done

echo "\nDone."
