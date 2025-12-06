#!/usr/bin/env bash
set -euo pipefail

# docker-registry-cleanup.sh
# Clean up old images from a private Docker registry (Docker Registry v2).
# Supports tag-based and digest-based deletion with age filtering.
# Dry-run by default; use --no-dry-run to delete images.

usage(){
  cat <<EOF
Usage: $0 --registry URL [--repository REPO] [--keep-tags N] [--older-than-days N] [--no-dry-run]

Options:
  --registry URL           Registry URL (e.g., registry.example.com:5000)
  --repository REPO        Specific repository to clean (default: all repositories)
  --keep-tags N            Keep N most recent tags per repository (default: 10)
  --older-than-days N      Only delete images older than N days (default: 90)
  --username USER          Registry username (optional, uses .docker/config.json if available)
  --password PASS          Registry password (optional)
  --no-dry-run             Delete images (default: dry-run)
  -h, --help               Show this help

Examples:
  # Dry-run: show images that would be deleted
  bash/docker-registry-cleanup.sh --registry localhost:5000 --keep-tags 5

  # Clean specific repository, keep 3 tags
  bash/docker-registry-cleanup.sh --registry registry.example.com --repository myapp --keep-tags 3 --no-dry-run

  # Delete images older than 180 days
  bash/docker-registry-cleanup.sh --registry registry.example.com --older-than-days 180 --no-dry-run

EOF
}

REGISTRY=""
REPOSITORY=""
KEEP_TAGS=10
OLDER_THAN_DAYS=90
USERNAME=""
PASSWORD=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY="$2"; shift 2;;
    --repository) REPOSITORY="$2"; shift 2;;
    --keep-tags) KEEP_TAGS="$2"; shift 2;;
    --older-than-days) OLDER_THAN_DAYS="$2"; shift 2;;
    --username) USERNAME="$2"; shift 2;;
    --password) PASSWORD="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$REGISTRY" ]]; then
  echo "--registry is required"; usage; exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required"; exit 3
fi

echo "Docker Registry Cleanup: registry=$REGISTRY repository=${REPOSITORY:-all} keep-tags=$KEEP_TAGS dry-run=$DRY_RUN"

# Build auth header if credentials provided
AUTH_HEADER=""
if [[ -n "$USERNAME" && -n "$PASSWORD" ]]; then
  AUTH_HEADER="-u $USERNAME:$PASSWORD"
fi

# Calculate threshold date
threshold_epoch=$(($(date +%s) - OLDER_THAN_DAYS * 86400))

# Get list of repositories
if [[ -n "$REPOSITORY" ]]; then
  repositories=("$REPOSITORY")
else
  echo "Fetching repository list..."
  repos_json=$(curl -s $AUTH_HEADER "https://$REGISTRY/v2/_catalog" || echo '{"repositories":[]}')
  mapfile -t repositories < <(echo "$repos_json" | jq -r '.repositories[]?')
fi

if [[ ${#repositories[@]} -eq 0 ]]; then
  echo "No repositories found"
  exit 0
fi

echo "Found ${#repositories[@]} repository/repositories to check"
echo ""

declare -i total_candidates=0

for repo in "${repositories[@]}"; do
  echo "=== Repository: $repo ==="
  
  # Get tags for this repository
  tags_json=$(curl -s $AUTH_HEADER "https://$REGISTRY/v2/$repo/tags/list" || echo '{"tags":[]}')
  mapfile -t tags < <(echo "$tags_json" | jq -r '.tags[]?' | grep -v null)
  
  if [[ ${#tags[@]} -eq 0 ]]; then
    echo "  No tags found"
    continue
  fi
  
  echo "  Found ${#tags[@]} tag(s)"
  
  # Get manifest and created date for each tag
  declare -A tag_dates
  
  for tag in "${tags[@]}"; do
    manifest=$(curl -s $AUTH_HEADER -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      "https://$REGISTRY/v2/$repo/manifests/$tag" 2>/dev/null || echo '{}')
    
    # Try to extract created date from manifest
    created=$(echo "$manifest" | jq -r '.history[0].v1Compatibility' 2>/dev/null | jq -r '.created' 2>/dev/null || echo "")
    
    if [[ -n "$created" && "$created" != "null" ]]; then
      created_epoch=$(date -d "$created" +%s 2>/dev/null || echo 0)
      tag_dates["$tag"]=$created_epoch
    else
      tag_dates["$tag"]=999999999999  # Keep if we can't determine age
    fi
  done
  
  # Sort tags by date (newest first)
  mapfile -t sorted_tags < <(
    for tag in "${!tag_dates[@]}"; do
      echo "${tag_dates[$tag]}:$tag"
    done | sort -rn | cut -d: -f2
  )
  
  # Determine which tags to delete
  declare -a delete_candidates
  
  for i in "${!sorted_tags[@]}"; do
    tag="${sorted_tags[$i]}"
    tag_epoch="${tag_dates[$tag]}"
    
    # Keep first N tags (most recent)
    if [[ $i -lt $KEEP_TAGS ]]; then
      age_days=$(( ($(date +%s) - tag_epoch) / 86400 ))
      echo "  KEEP: $tag (age=$age_days days, within keep-tags=$KEEP_TAGS)"
      continue
    fi
    
    # Check age threshold
    if [[ $tag_epoch -lt $threshold_epoch ]]; then
      age_days=$(( ($(date +%s) - tag_epoch) / 86400 ))
      echo "  DELETE: $tag (age=$age_days days)"
      delete_candidates+=("$tag")
      ((total_candidates++))
    fi
  done
  
  # Delete tags
  if [[ ${#delete_candidates[@]} -gt 0 ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "  DRY RUN: would delete ${#delete_candidates[@]} tag(s)"
    else
      for tag in "${delete_candidates[@]}"; do
        # Get digest for deletion
        digest=$(curl -s -I $AUTH_HEADER -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
          "https://$REGISTRY/v2/$repo/manifests/$tag" 2>/dev/null | \
          grep -i Docker-Content-Digest | awk '{print $2}' | tr -d '\r')
        
        if [[ -n "$digest" ]]; then
          echo "  Deleting $tag (digest: $digest)"
          curl -s -X DELETE $AUTH_HEADER "https://$REGISTRY/v2/$repo/manifests/$digest" 2>/dev/null || echo "    Failed"
        else
          echo "  Failed to get digest for $tag"
        fi
      done
    fi
  fi
  
  unset tag_dates delete_candidates sorted_tags
  echo ""
done

echo "=== Summary ==="
echo "Total images to delete: $total_candidates"

if [[ "$DRY_RUN" == false && $total_candidates -gt 0 ]]; then
  echo ""
  echo "⚠️  Note: Run 'docker exec <registry-container> bin/registry garbage-collect /etc/docker/registry/config.yml' to reclaim disk space"
fi

echo "Done."
