#!/usr/bin/env bash
set -euo pipefail

# Simple ECR image pruner. Lists untagged images and images older than X days.
# Dry-run by default. Requires `aws` and `jq`.
# Usage: aws-ecr-image-pruner.sh -r REPO -d DAYS [--dry-run]

usage(){
  cat <<EOF
Usage: $0 -r REPO -d DAYS [--dry-run]

Lists images in ECR repository and (dry-run) shows deletion commands for images older than DAYS
Options:
  -r REPO     ECR repository name
  -d DAYS     Age threshold in days
  --dry-run   Only print commands (default)
  --no-dry-run Actually perform deletions
  -h          Help
EOF
}

REPO=""
DAYS=0
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r) REPO="$2"; shift 2;;
    -d) DAYS="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown $1"; usage; exit 2;;
  esac
done

if [[ -z "$REPO" || $DAYS -le 0 ]]; then
  usage; exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required for parsing; please install jq"; exit 3
fi

cutoff=$(date -d "-$DAYS days" +%s)

echo "Listing images in $REPO older than $DAYS days (cutoff epoch=$cutoff)"

aws ecr describe-images --repository-name "$REPO" --query 'imageDetails[]' --output json |
  jq -c '.[] | {digest: .imageDigest, pushedAt: .imagePushedAt, tags: .imageTags}' | while read -r rec; do
    digest=$(echo "$rec" | jq -r '.digest')
    pushed=$(echo "$rec" | jq -r '.pushedAt')
    tags=$(echo "$rec" | jq -r '.tags | join(",")')
    if [[ "$pushed" == "null" ]]; then
      pe=0
    else
      pe=$(date -d "$pushed" +%s)
    fi
    if [[ $pe -lt $cutoff ]]; then
      if [[ "$DRY_RUN" == true ]]; then
        echo "DRY RUN: aws ecr batch-delete-image --repository-name $REPO --image-ids imageDigest=$digest"
      else
        echo "Deleting $digest"
        aws ecr batch-delete-image --repository-name "$REPO" --image-ids imageDigest="$digest"
      fi
    fi
  done

echo "Done."
