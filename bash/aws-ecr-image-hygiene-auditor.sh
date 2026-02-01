#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ecr-image-hygiene-auditor.log"
REPORT_FILE="/tmp/ecr-image-hygiene-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
OLDER_THAN_DAYS="${ECR_IMAGE_OLDER_THAN_DAYS:-30}"
DELETE_DRY_RUN="${ECR_DELETE_DRY_RUN:-true}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "ECR Image Hygiene Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Images older than (days): $OLDER_THAN_DAYS" >> "$REPORT_FILE"
  echo "Dry run delete: $DELETE_DRY_RUN" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

epoch_from_iso() { date -d "$1" +%s 2>/dev/null || echo 0; }

main() {
  write_header

  repos=$(aws ecr describe-repositories --region "$REGION" --output json 2>/dev/null | jq -r '.repositories[].repositoryName')
  if [ -z "$repos" ]; then
    echo "No ECR repositories found." >> "$REPORT_FILE"
    log_message "No ECR repositories in region $REGION"
    exit 0
  fi

  cutoff=$(( $(date +%s) - OLDER_THAN_DAYS * 86400 ))
  total_repos=0
  total_old=0
  total_untagged=0

  for repo in $repos; do
    total_repos=$((total_repos+1))
    echo "Repository: $repo" >> "$REPORT_FILE"

    images=$(aws ecr list-images --repository-name "$repo" --region "$REGION" --filter "tagStatus=ANY" --output json 2>/dev/null)
    image_ids=$(echo "$images" | jq -c '.imageIds[]?')
    if [ -z "$image_ids" ]; then
      echo "  No images." >> "$REPORT_FILE"
      continue
    fi

    echo "$images" | jq -c '.imageIds[]?' | while read -r img; do
      imageDigest=$(echo "$img" | jq -r '.imageDigest // ""')
      imageTag=$(echo "$img" | jq -r '.imageTag // "<untagged>"')

      # Get image details
      details=$(aws ecr describe-images --repository-name "$repo" --image-ids imageDigest=$imageDigest${imageTag:+,imageTag=$imageTag} --region "$REGION" --output json 2>/dev/null || echo '{}')
      pushedAt=$(echo "$details" | jq -r '.imageDetails[0].imagePushedAt // empty')
      pushed_epoch=0
      if [ -n "$pushedAt" ]; then
        pushed_epoch=$(epoch_from_iso "$pushedAt")
      fi

      age_days=0
      if [ "$pushed_epoch" -gt 0 ]; then
        age_days=$(( ( $(date +%s) - pushed_epoch ) / 86400 ))
      fi

      echo "  Image: ${imageTag} ${imageDigest}" >> "$REPORT_FILE"
      echo "    PushedAt: ${pushedAt} (age ${age_days} days)" >> "$REPORT_FILE"

      if [ "$imageTag" = "<untagged>" ]; then
        total_untagged=$((total_untagged+1))
        echo "    NOTE: untagged image" >> "$REPORT_FILE"
        send_slack_alert "ECR Notice: Untagged image in $repo ${imageDigest}"
      fi

      if [ "$pushed_epoch" -gt 0 ] && [ "$pushed_epoch" -le "$cutoff" ]; then
        total_old=$((total_old+1))
        echo "    ALERT: image older than ${OLDER_THAN_DAYS} days" >> "$REPORT_FILE"
        if [ "$DELETE_DRY_RUN" = "false" ]; then
          aws ecr batch-delete-image --repository-name "$repo" --image-ids imageDigest=$imageDigest${imageTag:+,imageTag=$imageTag} --region "$REGION" >/dev/null 2>&1 || true
          send_slack_alert "ECR Action: Deleted image ${imageDigest} (${imageTag}) from $repo"
        else
          send_slack_alert "ECR Alert: Image ${imageDigest} (${imageTag}) in $repo older than ${OLDER_THAN_DAYS} days (dry-run)"
        fi
      fi
    done
  done

  echo "Summary: repos=$total_repos, old_images=$total_old, untagged_images=$total_untagged" >> "$REPORT_FILE"
  log_message "ECR hygiene report written to $REPORT_FILE (repos=$total_repos, old_images=$total_old, untagged_images=$total_untagged)"
}

main "$@"
