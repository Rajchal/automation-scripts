#!/usr/bin/env bash
set -euo pipefail

# Audit AWS Config configuration recorders and delivery channels.
# Dry-run by default. Can optionally start stopped recorders with --start --no-dry-run.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--start] [--no-dry-run]

Options:
  --region REGION      AWS region (uses AWS_DEFAULT_REGION if unset)
  --start              Attempt to start stopped configuration recorders (requires --no-dry-run)
  --dry-run            Default; only print actions
  --no-dry-run         Apply changes when requested
  -h, --help           Show this help

Examples:
  # Dry-run: list recorder and delivery channel statuses
  bash/aws-config-recorder-status-auditor.sh

  # Start stopped recorders (apply)
  bash/aws-config-recorder-status-auditor.sh --start --no-dry-run

EOF
}

REGION=""
DO_START=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --start) DO_START=true; shift;;
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

AWS=(aws)
CFG=(aws configservice)
if [[ -n "$REGION" ]]; then
  AWS+=(--region "$REGION")
  CFG+=(--region "$REGION")
fi

echo "AWS Config recorder auditor: start=$DO_START dry-run=$DRY_RUN"

echo "Listing configuration recorders..."
recs_json=$(${CFG[*]} describe-configuration-recorders --output json 2>/dev/null || echo '{}')
mapfile -t recs < <(echo "$recs_json" | jq -r '.ConfigurationRecorders[]? | @base64')

if [[ ${#recs[@]} -eq 0 ]]; then
  echo "No configuration recorders found.";
else
  echo "Recorders:";
  for r in "${recs[@]}"; do
    rec=$(echo "$r" | base64 --decode)
    name=$(echo "$rec" | jq -r '.name // .name' 2>/dev/null || echo '')
    # Describe status
    status_json=$(${CFG[*]} describe-configuration-recorder-status --configuration-recorder-names "$name" --output json 2>/dev/null || echo '{}')
    last_status=$(echo "$status_json" | jq -r '.ConfigurationRecordersStatus[0].lastStatus // empty')
    last_error=$(echo "$status_json" | jq -r '.ConfigurationRecordersStatus[0].lastErrorMessage // empty')
    last_status_time=$(echo "$status_json" | jq -r '.ConfigurationRecordersStatus[0].lastStatusChangeTime // empty')
    echo " - $name status=${last_status:-unknown} last_change=$last_status_time"
    if [[ -n "$last_error" && "$last_error" != "null" ]]; then
      echo "     error: $last_error"
    fi
    if [[ "$last_status" != "SUCCESS" && "$last_status" != "RUNNING" ]]; then
      candidates+=("$name:$last_status:$last_status_time")
    fi
  done
fi

echo "\nListing delivery channels..."
dc_json=$(${CFG[*]} describe-delivery-channels --output json 2>/dev/null || echo '{}')
mapfile -t channels < <(echo "$dc_json" | jq -r '.DeliveryChannels[]? | @base64')
if [[ ${#channels[@]} -eq 0 ]]; then
  echo "No delivery channels found.";
else
  for c in "${channels[@]}"; do
    rec=$(echo "$c" | base64 --decode)
    name=$(echo "$rec" | jq -r '.name // empty')
    s3bucket=$(echo "$rec" | jq -r '.s3BucketName // empty')
    sns=$(echo "$rec" | jq -r '.snsTopicARN // empty')
    echo " - channel $name s3=$s3bucket sns=$sns"
  done
fi

declare -a candidates

if [[ -z "${candidates[*]:-}" ]]; then
  echo "\nNo stopped/misconfigured recorders detected based on lastStatus."
else
  echo "\nCandidate recorders to start:";
  for ent in "${candidates[@]}"; do
    name=${ent%%:*}
    status=${ent#*:}
    echo " - $name status=$status"
  done
fi

if [[ "$DO_START" == false ]]; then
  echo "\nNo action requested. To start stopped recorders re-run with --start --no-dry-run"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: would start the candidate recorders. Re-run with --no-dry-run to apply."
  exit 0
fi

echo "Starting candidate recorders..."
for ent in "${candidates[@]}"; do
  name=${ent%%:*}
  echo "Starting configuration recorder $name"
  ${CFG[*]} start-configuration-recorder --configuration-recorder-name "$name" || echo "Failed to start $name"
done

echo "Done."
