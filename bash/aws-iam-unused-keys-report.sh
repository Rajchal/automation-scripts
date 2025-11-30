#!/usr/bin/env bash
set -euo pipefail

# Report IAM access keys that appear unused (by last-used date) and optionally deactivate them.
# Dry-run by default.
# Usage: aws-iam-unused-keys-report.sh [--user NAME | --all] [--age DAYS] [--deactivate] [--no-dry-run]

usage(){
  cat <<EOF
Usage: $0 [--user NAME | --all] [--age DAYS] [--deactivate] [--no-dry-run]

Options:
  --user NAME     Check a specific IAM user
  --all           Check all users (default)
  --age DAYS      Consider keys unused if last used more than DAYS ago (default: 90)
  --deactivate    Deactivate keys identified as unused (requires --no-dry-run)
  --dry-run       Show actions only (default)
  --no-dry-run    Perform actions (e.g. deactivate)
  -h, --help      Show this help

Examples:
  # Dry-run, list keys not used in 90 days
  bash/aws-iam-unused-keys-report.sh --all --age 90

  # Deactivate unused keys older than 180 days (will prompt if dry-run)
  bash/aws-iam-unused-keys-report.sh --all --age 180 --deactivate --no-dry-run

EOF
}

USER_FILTER=""
CHECK_ALL=true
AGE_DAYS=90
DRY_RUN=true
DEACTIVATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_FILTER="$2"; CHECK_ALL=false; shift 2;;
    --all) CHECK_ALL=true; shift;;
    --age) AGE_DAYS="$2"; shift 2;;
    --deactivate) DEACTIVATE=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not found; please install and configure credentials."; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required; please install jq."; exit 3
fi

echo "Checking IAM access keys: age threshold = $AGE_DAYS days; dry-run=$DRY_RUN; deactivate=$DEACTIVATE"

cutoff_epoch=$(date -d "-$AGE_DAYS days" +%s)

users=()
if [[ "$CHECK_ALL" == true ]]; then
  mapfile -t users < <(aws iam list-users --query 'Users[].UserName' --output text)
else
  users=("$USER_FILTER")
fi

if [[ ${#users[@]} -eq 0 ]]; then
  echo "No users found to check."; exit 0
fi

echo "Found ${#users[@]} user(s) to check"

declare -a to_deactivate

for u in "${users[@]}"; do
  echo "\nUser: $u"
  # list access keys for user
  keys_json=$(aws iam list-access-keys --user-name "$u" --query 'AccessKeyMetadata' --output json)
  if [[ "$keys_json" == "[]" ]]; then
    echo "  No access keys for $u"
    continue
  fi

  echo "$keys_json" | jq -c '.[]' | while read -r meta; do
    ak=$(echo "$meta" | jq -r '.AccessKeyId')
    status=$(echo "$meta" | jq -r '.Status')
    create_date=$(echo "$meta" | jq -r '.CreateDate')

    # get last used date (may be empty)
    last_used_raw=$(aws iam get-access-key-last-used --access-key-id "$ak" --query 'AccessKeyLastUsed.LastUsedDate' --output text 2>/dev/null || true)
    if [[ "$last_used_raw" == "None" || -z "$last_used_raw" || "$last_used_raw" == "null" ]]; then
      # never used / no info
      echo "  Key $ak (Status=$status) - never used or no last-used info (created: $create_date)"
      to_deactivate+=("$u:$ak")
      continue
    fi

    # convert last used to epoch
    last_used_epoch=$(date -d "$last_used_raw" +%s)
    if [[ $last_used_epoch -lt $cutoff_epoch ]]; then
      days_old=$(( ( $(date +%s) - last_used_epoch ) / 86400 ))
      echo "  Key $ak (Status=$status) - last used $last_used_raw (~${days_old} days ago)"
      to_deactivate+=("$u:$ak")
    else
      echo "  Key $ak (Status=$status) - last used recently: $last_used_raw"
    fi
  done
done

if [[ ${#to_deactivate[@]} -eq 0 ]]; then
  echo "\nNo candidate keys found for deactivation based on age=$AGE_DAYS days."
  exit 0
fi

echo "\nCandidates for deactivation:"
for pair in "${to_deactivate[@]}"; do
  user=${pair%%:*}
  ak=${pair#*:}
  echo " - $user : $ak"
done

if [[ "$DEACTIVATE" == false ]]; then
  echo "\nRun with --deactivate --no-dry-run to deactivate these keys.";
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN enabled: no keys will be deactivated. Re-run with --no-dry-run to apply changes.";
  exit 0
fi

echo "\nDeactivating keys..."
for pair in "${to_deactivate[@]}"; do
  user=${pair%%:*}
  ak=${pair#*:}
  echo "Deactivating $ak for user $user"
  aws iam update-access-key --user-name "$user" --access-key-id "$ak" --status Inactive
done

echo "Done."
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
