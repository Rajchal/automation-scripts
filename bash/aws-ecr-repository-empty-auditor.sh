#!/usr/bin/env bash
set -euo pipefail

# Find empty or stale ECR repositories and optionally tag or delete them.
# Dry-run by default.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--stale-days N] [--tag] [--delete] [--no-dry-run]

Options:
  --region REGION      AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N             Lookback window in days for listing (default: 90)
  --stale-days N       Consider repo stale if last image push older than this (default: 180)
  --tag                Tag candidate repositories with Key=idle_candidate,Value=true
  --delete             Delete empty repositories (dangerous)
  --dry-run            Default; only print actions
  --no-dry-run         Apply tagging/deletion when requested
  -h, --help           Show this help

Examples:
  # Dry-run: list empty or stale repos
  bash/aws-ecr-repository-empty-auditor.sh --stale-days 180

  # To tag candidates (requires --no-dry-run)
  bash/aws-ecr-repository-empty-auditor.sh --tag --no-dry-run

  # To delete empty repositories (requires --no-dry-run)
  bash/aws-ecr-repository-empty-auditor.sh --delete --no-dry-run

EOF
}

REGION=""
DAYS=90
STALE_DAYS=180
DO_TAG=false
DO_DELETE=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --stale-days) STALE_DAYS="$2"; shift 2;;
    --tag) DO_TAG=true; shift;;
    --delete) DO_DELETE=true; shift;;
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

ECR=(aws ecr)
if [[ -n "$REGION" ]]; then
  ECR+=(--region "$REGION")
fi

echo "ECR repo auditor: stale-days=$STALE_DAYS tag=$DO_TAG delete=$DO_DELETE dry-run=$DRY_RUN"

cutoff=$(date -u -d "-$STALE_DAYS days" +%s)

repos_json=$(${ECR[*]} describe-repositories --output json 2>/dev/null || echo '{}')
mapfile -t repos < <(echo "$repos_json" | jq -r '.repositories[]? | @base64')

if [[ ${#repos[@]} -eq 0 ]]; then
  echo "No ECR repositories found."; exit 0
fi

declare -a empty_repos
declare -a stale_repos

for r in "${repos[@]}"; do
  rec=$(echo "$r" | base64 --decode)
  name=$(echo "$rec" | jq -r '.repositoryName')
  arn=$(echo "$rec" | jq -r '.repositoryArn')

  images_json=$(${ECR[*]} describe-images --repository-name "$name" --query 'imageDetails[]' --output json 2>/dev/null || echo '[]')
  image_count=$(echo "$images_json" | jq 'length')

  if [[ $image_count -eq 0 ]]; then
    empty_repos+=("$name:$arn")
    continue
  fi

  # Find most recent push time
  last_pushed=$(echo "$images_json" | jq -r '.[].imagePushedAt' | sort -r | head -n1)
  if [[ -z "$last_pushed" || "$last_pushed" == "null" ]]; then
    # If no push timestamp, treat as stale candidate
    stale_repos+=("$name:$arn:unknown")
    continue
  fi
  last_ts=$(date -u -d "$last_pushed" +%s)
  if [[ $last_ts -le $cutoff ]]; then
    stale_repos+=("$name:$arn:$last_pushed")
  fi
done

if [[ ${#empty_repos[@]} -eq 0 && ${#stale_repos[@]} -eq 0 ]]; then
  echo "No empty or stale repositories found."; exit 0
fi

if [[ ${#empty_repos[@]} -gt 0 ]]; then
  echo "Empty repositories:";
  for e in "${empty_repos[@]}"; do
    name=${e%%:*}
    echo " - $name"
  done
fi

if [[ ${#stale_repos[@]} -gt 0 ]]; then
  echo "\nStale repositories (last push):"
  for s in "${stale_repos[@]}"; do
    name=${s%%:*}
    rest=${s#*:}
    arn=${rest%%:*}
    pushed=${rest#*:}
    echo " - $name last_push=$pushed"
  done
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: no tags or deletions performed. Re-run with --no-dry-run and --tag/--delete to act."
  exit 0
fi

if [[ "$DO_TAG" == true ]]; then
  echo "\nTagging candidates with Key=idle_candidate,Value=true"
  for e in "${empty_repos[@]}"; do
    name=${e%%:*}
    arn=${e#*:}
    echo "Tagging $name"
    ${ECR[*]} tag-resource --resource-arn "$arn" --tags Key=idle_candidate,Value=true || echo "Failed to tag $name"
  done
  for s in "${stale_repos[@]}"; do
    name=${s%%:*}
    arn=$(echo "$s" | cut -d: -f2)
    echo "Tagging $name"
    ${ECR[*]} tag-resource --resource-arn "$arn" --tags Key=idle_candidate,Value=true || echo "Failed to tag $name"
  done
fi

if [[ "$DO_DELETE" == true ]]; then
  echo "\nDeleting empty repositories (will only delete truly empty repos)"
  for e in "${empty_repos[@]}"; do
    name=${e%%:*}
    echo "Deleting $name"
    ${ECR[*]} delete-repository --repository-name "$name" || echo "Failed to delete $name"
  done
fi

echo "Done."
