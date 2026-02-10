#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ecr-image-hygiene-auditor.log"
REPORT_FILE="/tmp/ecr-image-hygiene-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
OLD_DAYS="${ECR_IMAGE_OLD_DAYS:-90}"
SEVERITY_THRESHOLD="${ECR_HIGH_SEVERITY_THRESHOLD:-7}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS ECR Image Hygiene Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Old threshold (days): $OLD_DAYS" >> "$REPORT_FILE"
  echo "Severity threshold (high): $SEVERITY_THRESHOLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_repository() {
  local repo="$1"
  echo "Repository: $repo" >> "$REPORT_FILE"

  aws ecr list-images --repository-name "$repo" --output json --filter tagStatus=ANY 2>/dev/null | jq -c '.imageIds[]? // empty' | while read -r img; do
    digest=$(echo "$img" | jq -r '.imageDigest // empty')
    tag=$(echo "$img" | jq -r '.imageTag // "<untagged>"')

    # describe image for details
    img_json=$(aws ecr describe-images --repository-name "$repo" --image-ids imageDigest="$digest" --output json 2>/dev/null || echo '{}')
    pushed_at=$(echo "$img_json" | jq -r '.imageDetails[0].imagePushedAt // empty')
    scan_status=$(echo "$img_json" | jq -r '.imageDetails[0].imageScanStatus.status // empty')
    finding_severity=$(echo "$img_json" | jq -r '.imageDetails[0].imageScanFindingsSummary.highestSeverity || empty' 2>/dev/null || true)

    if [ -n "$pushed_at" ] && [ "$pushed_at" != "null" ]; then
      pushed_epoch=$(date -d "$pushed_at" +%s 2>/dev/null || true)
      if [ -n "$pushed_epoch" ]; then
        age_days=$(( ( $(date +%s) - pushed_epoch ) / 86400 ))
      else
        age_days=0
      fi
    else
      age_days=0
    fi

    line="  Image: tag=$tag digest=$digest age=${age_days}d scan=$scan_status severity=$finding_severity"
    echo "$line" >> "$REPORT_FILE"

    if [ "$tag" = "<untagged>" ]; then
      echo "    UNTAGGED_IMAGE" >> "$REPORT_FILE"
      send_slack_alert "ECR Alert: UnTagged image in $repo (digest=$digest)"
    fi

    if [ "$age_days" -ge "$OLD_DAYS" ]; then
      echo "    OLD_IMAGE: ${age_days}d" >> "$REPORT_FILE"
      send_slack_alert "ECR Alert: Image $tag ($digest) in $repo is ${age_days} days old"
    fi

    # check scan severity if available
    if [ -n "$finding_severity" ] && [ "$finding_severity" != "UNKNOWN" ]; then
      # try numeric compare: map severities to numeric scale if necessary
      case "$finding_severity" in
        CRITICAL) sevnum=9 ;;
        HIGH) sevnum=7 ;;
        MEDIUM) sevnum=5 ;;
        LOW) sevnum=3 ;;
        INFORMATIONAL) sevnum=1 ;;
        *) sevnum=0 ;;
      esac
      if [ "$sevnum" -ge "$SEVERITY_THRESHOLD" ]; then
        echo "    HIGH_SEVERITY_FINDING: $finding_severity" >> "$REPORT_FILE"
        send_slack_alert "ECR Alert: Image $tag in $repo has high severity findings ($finding_severity)"
      fi
    else
      if [ "$scan_status" != "COMPLETE" ]; then
        echo "    NOT_SCANNED_OR_INCOMPLETE: status=$scan_status" >> "$REPORT_FILE"
      fi
    fi

    echo "" >> "$REPORT_FILE"
  done
}

main() {
  write_header

  aws ecr describe-repositories --output json 2>/dev/null | jq -c '.repositories[]? // empty' | while read -r r; do
    name=$(echo "$r" | jq -r '.repositoryName')
    check_repository "$name"
  done

  log_message "ECR image hygiene audit written to $REPORT_FILE"
}

main "$@"
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
