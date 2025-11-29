#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [--days N] [--deactivate] [--region REGION]

Scans IAM users for access keys not used in the last N days (default 90).
Options:
  --days N        threshold days (default 90)
  --deactivate    disable keys that exceed the threshold (prompted)
  --region REGION AWS region for API calls (optional)

Requires: awscli + jq
EOF
}

DAYS=90
DEACTIVATE=0
REGION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="$2"; shift 2;;
    --deactivate) DEACTIVATE=1; shift 1;;
    --region) REGION="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

AWS_CLI=(aws)
if [[ -n "$REGION" ]]; then AWS_CLI+=(--region "$REGION"); fi

THRESHOLD_TS=$(date -d "-$DAYS days" +%s)

echo "Scanning IAM users for access keys unused for >= $DAYS days"
mapfile -t USERS < <(${AWS_CLI[*]} iam list-users --query 'Users[].UserName' --output text)

for user in "${USERS[@]}"; do
  mapfile -t KEYS < <(${AWS_CLI[*]} iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text)
  for key in "${KEYS[@]}"; do
    last_used=$(${AWS_CLI[*]} iam get-access-key-last-used --access-key-id "$key" --query 'AccessKeyLastUsed.LastUsedDate' --output text)
    if [[ "$last_used" == "None" || -z "$last_used" ]]; then
      echo "User=$user Key=$key LastUsed=NEVER"
      if (( DEACTIVATE )); then
        read -r -p "Deactivate key $key for $user? [y/N] " reply
        if [[ "$reply" =~ ^[Yy]$ ]]; then
          ${AWS_CLI[*]} iam update-access-key --user-name "$user" --access-key-id "$key" --status Inactive
          echo "Deactivated $key"
        fi
      fi
      continue
    fi
    # convert to seconds
    last_used_ts=$(date -d "$last_used" +%s)
    if (( last_used_ts <= THRESHOLD_TS )); then
      echo "User=$user Key=$key LastUsed=$last_used (older than $DAYS days)"
      if (( DEACTIVATE )); then
        read -r -p "Deactivate key $key for $user? [y/N] " reply
        if [[ "$reply" =~ ^[Yy]$ ]]; then
          ${AWS_CLI[*]} iam update-access-key --user-name "$user" --access-key-id "$key" --status Inactive
          echo "Deactivated $key"
        fi
      fi
    fi
  done
done

echo "Scan complete."
