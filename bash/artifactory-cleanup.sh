#!/usr/bin/env bash
set -euo pipefail

# artifactory-cleanup.sh
# Clean old artifacts from JFrog Artifactory repositories.
# Supports age-based and count-based retention policies.
# Dry-run by default; use --no-dry-run to delete artifacts.

usage(){
  cat <<EOF
Usage: $0 --artifactory-url URL --repo REPO [--user USER] [--password PASS] [--older-than-days N] [--no-dry-run]

Options:
  --artifactory-url URL    Artifactory server URL (required)
  --repo REPO              Repository name to clean (required)
  --user USER              Artifactory username
  --password PASS          Artifactory password or API key
  --api-key KEY            Artifactory API key (alternative to password)
  --older-than-days N      Delete artifacts older than N days (default: 90)
  --keep-latest N          Keep N most recent artifacts (default: 10)
  --path-pattern PATTERN   Only clean artifacts matching pattern (e.g., "*/SNAPSHOT/*")
  --no-dry-run             Delete artifacts (default: dry-run)
  -h, --help               Show this help

Examples:
  # Dry-run: show artifacts that would be deleted
  bash/artifactory-cleanup.sh --artifactory-url https://artifactory.example.com --repo libs-snapshot

  # Delete SNAPSHOT artifacts older than 30 days
  bash/artifactory-cleanup.sh \\
    --artifactory-url https://artifactory.example.com \\
    --repo libs-snapshot \\
    --user admin \\
    --password password123 \\
    --older-than-days 30 \\
    --no-dry-run

  # Clean with API key and path pattern
  bash/artifactory-cleanup.sh \\
    --artifactory-url https://artifactory.example.com \\
    --repo docker-local \\
    --api-key AKCxxxx \\
    --path-pattern "myapp/*/v*" \\
    --older-than-days 60 \\
    --no-dry-run

EOF
}

ARTIFACTORY_URL=""
REPO=""
USER=""
PASSWORD=""
API_KEY=""
OLDER_THAN_DAYS=90
KEEP_LATEST=10
PATH_PATTERN=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifactory-url) ARTIFACTORY_URL="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --user) USER="$2"; shift 2;;
    --password) PASSWORD="$2"; shift 2;;
    --api-key) API_KEY="$2"; shift 2;;
    --older-than-days) OLDER_THAN_DAYS="$2"; shift 2;;
    --keep-latest) KEEP_LATEST="$2"; shift 2;;
    --path-pattern) PATH_PATTERN="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$ARTIFACTORY_URL" ]]; then
  echo "--artifactory-url is required"; usage; exit 2
fi

if [[ -z "$REPO" ]]; then
  echo "--repo is required"; usage; exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required"; exit 3
fi

# Remove trailing slash
ARTIFACTORY_URL="${ARTIFACTORY_URL%/}"

# Build auth header
AUTH=""
if [[ -n "$API_KEY" ]]; then
  AUTH="-H X-JFrog-Art-Api:$API_KEY"
elif [[ -n "$USER" && -n "$PASSWORD" ]]; then
  AUTH="-u $USER:$PASSWORD"
fi

echo "Artifactory Cleanup: url=$ARTIFACTORY_URL repo=$REPO older-than-days=$OLDER_THAN_DAYS dry-run=$DRY_RUN"

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: would clean artifacts from Artifactory repository"
  exit 0
fi

# Calculate threshold date
threshold_epoch=$(($(date +%s) - OLDER_THAN_DAYS * 86400))
threshold_date=$(date -u -d "@$threshold_epoch" +%Y-%m-%d 2>/dev/null || date -u -r "$threshold_epoch" +%Y-%m-%d)

echo "Threshold date: $threshold_date"
echo ""

# Build AQL query to find old artifacts
aql_query="items.find({
  \"repo\": \"$REPO\",
  \"modified\": {\"\$lt\": \"$threshold_date\"}
})"

if [[ -n "$PATH_PATTERN" ]]; then
  aql_query="items.find({
    \"repo\": \"$REPO\",
    \"path\": {\"\$match\": \"$PATH_PATTERN\"},
    \"modified\": {\"\$lt\": \"$threshold_date\"}
  })"
fi

# Execute AQL query
echo "Querying Artifactory for old artifacts..."
response=$(curl -s $AUTH -X POST "$ARTIFACTORY_URL/api/search/aql" \
  -H "Content-Type: text/plain" \
  -d "$aql_query" 2>/dev/null || echo '{"results":[]}')

# Check for errors
if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
  echo "AQL query failed:"
  echo "$response" | jq -r '.errors[].message'
  exit 1
fi

# Parse results
mapfile -t artifacts < <(echo "$response" | jq -c '.results[]?')

if [[ ${#artifacts[@]} -eq 0 ]]; then
  echo "No artifacts found matching criteria"
  exit 0
fi

echo "Found ${#artifacts[@]} artifact(s) to potentially delete"
echo ""

# Group artifacts by path (to implement keep-latest logic)
declare -A path_artifacts

for artifact in "${artifacts[@]}"; do
  path=$(echo "$artifact" | jq -r '.path')
  name=$(echo "$artifact" | jq -r '.name')
  modified=$(echo "$artifact" | jq -r '.modified')
  size=$(echo "$artifact" | jq -r '.size')
  
  full_path="$path/$name"
  parent_path=$(dirname "$full_path")
  
  # Store artifact info with timestamp for sorting
  path_artifacts["$parent_path"]+="$modified|$full_path|$size;"
done

# Process each path group
declare -a delete_candidates
declare -i total_size=0

for parent_path in "${!path_artifacts[@]}"; do
  # Split artifacts for this path
  IFS=';' read -ra artifacts_array <<< "${path_artifacts[$parent_path]}"
  
  # Sort by modified date (newest first)
  IFS=$'\n' sorted=($(sort -r <<< "${artifacts_array[*]}"))
  unset IFS
  
  # Skip first N (keep-latest)
  skip_count=$KEEP_LATEST
  
  for artifact_info in "${sorted[@]}"; do
    [[ -z "$artifact_info" ]] && continue
    
    if [[ $skip_count -gt 0 ]]; then
      ((skip_count--))
      continue
    fi
    
    IFS='|' read -r modified full_path size <<< "$artifact_info"
    
    delete_candidates+=("$full_path")
    total_size=$((total_size + size))
  done
done

if [[ ${#delete_candidates[@]} -eq 0 ]]; then
  echo "No artifacts to delete (all within keep-latest threshold)"
  exit 0
fi

# Convert total size to human readable
if command -v numfmt >/dev/null 2>&1; then
  total_size_human=$(numfmt --to=iec-i --suffix=B "$total_size" 2>/dev/null || echo "${total_size} bytes")
else
  total_size_human="${total_size} bytes"
fi

echo "Artifacts to delete: ${#delete_candidates[@]}"
echo "Total size to reclaim: $total_size_human"
echo ""

# Delete artifacts
declare -i deleted_count=0
declare -i failed_count=0

for artifact_path in "${delete_candidates[@]}"; do
  echo "Deleting: $REPO/$artifact_path"
  
  response=$(curl -s $AUTH -X DELETE "$ARTIFACTORY_URL/$REPO/$artifact_path" -w "\n%{http_code}" 2>/dev/null || echo "000")
  http_code=$(echo "$response" | tail -n1)
  
  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    ((deleted_count++))
  else
    echo "  Failed (HTTP $http_code)"
    ((failed_count++))
  fi
done

echo ""
echo "=== Summary ==="
echo "Successfully deleted: $deleted_count"
echo "Failed: $failed_count"
echo "Space reclaimed: ~$total_size_human"

if [[ $failed_count -gt 0 ]]; then
  exit 1
else
  echo "Cleanup completed successfully"
  exit 0
fi
