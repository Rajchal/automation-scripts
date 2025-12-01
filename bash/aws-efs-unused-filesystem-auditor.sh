#!/usr/bin/env bash
set -euo pipefail

# Audit EFS filesystems for low activity (client connections and IO) and optionally tag candidates.
# Dry-run by default. Deleting EFS requires removing mount targets and is potentially destructive; this script only tags candidates.
# Usage: aws-efs-unused-filesystem-auditor.sh [--region REGION] [--days N] [--io-threshold BYTES] [--conn-threshold N] [--tag] [--no-dry-run]

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--io-threshold BYTES] [--conn-threshold N] [--tag] [--no-dry-run]

Options:
  --region REGION      AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N             Lookback window in days for CloudWatch metrics (default: 14)
  --io-threshold BYTES Consider filesystem idle if total IO (read+write) over window <= BYTES (default: 1,000,000 = 1MB)
  --conn-threshold N   Consider idle if average client connections < N (default: 1)
  --tag                Tag candidate filesystems with Key=idle_candidate,Value=true (requires --no-dry-run)
  --dry-run            Default; only print actions
  --no-dry-run         Perform tagging when requested
  -h, --help           Show this help

Example (dry-run):
  bash/aws-efs-unused-filesystem-auditor.sh --days 14 --io-threshold 1000000 --conn-threshold 1

To tag candidates:
  bash/aws-efs-unused-filesystem-auditor.sh --days 14 --io-threshold 1000000 --conn-threshold 1 --tag --no-dry-run

EOF
}

REGION=""
DAYS=14
IO_THRESHOLD=1000000
CONN_THRESHOLD=1
DO_TAG=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --io-threshold) IO_THRESHOLD="$2"; shift 2;;
    --conn-threshold) CONN_THRESHOLD="$2"; shift 2;;
    --tag) DO_TAG=true; shift;;
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

EFS=(aws efs)
CW=(aws cloudwatch)
if [[ -n "$REGION" ]]; then
  EFS+=(--region "$REGION")
  CW+=(--region "$REGION")
fi

echo "EFS auditor: days=$DAYS io-threshold=$IO_THRESHOLD bytes conn-threshold=$CONN_THRESHOLD tag=$DO_TAG dry-run=$DRY_RUN"

end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_time=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)

echo "Listing EFS filesystems..."
efs_json=$(${EFS[*]} describe-file-systems --query 'FileSystems[].[FileSystemId,Name,LifeCycleState]' --output json)
mapfile -t efs_list < <(echo "$efs_json" | jq -r '.[] | @base64')

if [[ ${#efs_list[@]} -eq 0 ]]; then
  echo "No EFS filesystems found."; exit 0
fi

declare -a candidates

for item in "${efs_list[@]}"; do
  rec=$(echo "$item" | base64 --decode | jq -r '.')
  fsid=$(echo "$rec" | jq -r '.[0]')
  name=$(echo "$rec" | jq -r '.[1] // empty')
  state=$(echo "$rec" | jq -r '.[2]')

  if [[ "$state" != "available" ]]; then
    echo "Skipping $fsid (state=$state)"
    continue
  fi

  display_name="$fsid"
  if [[ -n "$name" ]]; then display_name="$name ($fsid)"; fi
  echo "Checking $display_name"

  # Sum read + write bytes over window using CloudWatch metric 'DataReadIOBytes' and 'DataWriteIOBytes'
  resp_read=$(${CW[*]} get-metric-statistics --namespace AWS/EFS --metric-name DataReadIOBytes --statistics Sum --period 86400 --start-time "$start_time" --end-time "$end_time" --dimensions Name=FileSystemId,Value=$fsid --output json 2>/dev/null || echo '{}')
  resp_write=$(${CW[*]} get-metric-statistics --namespace AWS/EFS --metric-name DataWriteIOBytes --statistics Sum --period 86400 --start-time "$start_time" --end-time "$end_time" --dimensions Name=FileSystemId,Value=$fsid --output json 2>/dev/null || echo '{}')

  read_total=$(echo "$resp_read" | jq -r '[.Datapoints[].Sum] | add // 0')
  write_total=$(echo "$resp_write" | jq -r '[.Datapoints[].Sum] | add // 0')
  read_total=${read_total:-0}
  write_total=${write_total:-0}
  io_total=$(awk -v r="$read_total" -v w="$write_total" 'BEGIN{printf("%d", (r + w))}')

  # Average client connections
  resp_conn=$(${CW[*]} get-metric-statistics --namespace AWS/EFS --metric-name ClientConnections --statistics Average --period 3600 --start-time "$start_time" --end-time "$end_time" --dimensions Name=FileSystemId,Value=$fsid --output json 2>/dev/null || echo '{}')
  conn_avg=$(echo "$resp_conn" | jq -r '[.Datapoints[].Average] | if length==0 then 0 else (add / length) end')
  conn_avg=${conn_avg:-0}
  conn_avg_fmt=$(printf "%.2f" "$conn_avg")

  echo "  total IO over ${DAYS}d = $io_total bytes; avg client connections = $conn_avg_fmt"

  if [[ $io_total -le $IO_THRESHOLD && $(awk -v c="$conn_avg" -v t="$CONN_THRESHOLD" 'BEGIN{print (c < t) ? 1 : 0}') -eq 1 ]]; then
    candidates+=("$fsid:$display_name:$io_total:$conn_avg_fmt")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No idle EFS filesystems found."; exit 0
fi

echo "\nCandidate idle filesystems:"
for c in "${candidates[@]}"; do
  fsid=${c%%:*}
  rest=${c#*:}
  name=${rest%%:*}
  rest2=${rest#*:}
  io=${rest2%%:*}
  conn=${rest2#*:}
  echo " - $name (id=$fsid) io=${io} bytes, avg_conn=${conn}"
done

if [[ "$DO_TAG" == false ]]; then
  echo "\nNo action requested. To tag these filesystems re-run with --tag --no-dry-run"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: would tag the candidate filesystems with Key=idle_candidate,Value=true. Re-run with --no-dry-run to apply."
  exit 0
fi

for c in "${candidates[@]}"; do
  fsid=${c%%:*}
  echo "Tagging $fsid: idle_candidate=true"
  ${EFS[*]} tag-resource --resource-id "$fsid" --tags Key=idle_candidate,Value=true
done

echo "Done."
