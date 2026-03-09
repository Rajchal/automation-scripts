#!/usr/bin/env bash
set -euo pipefail

# artifactory_cleanup.sh
# Find and optionally delete Artifactory artifacts older than N days.

usage() {
  cat <<EOF
Usage: $0 --repo REPO --days N [--url URL] [--path-prefix PREFIX] [--apply]

Options:
  --url URL            Artifactory base URL (or set ARTIFACTORY_URL)
  --repo REPO          Repository name
  --days N             Match artifacts older than N days
  --path-prefix P      Restrict to path prefix
  --apply              Perform deletions (default: dry-run)
  -h, --help           Show this help

Auth:
  - API key via env: X_JFROG_ART_API or ARTIFACTORY_API_KEY or X-JFrog-Art-Api
  - Or basic auth via ART_USER and ART_PASSWORD

Examples:
  bash/artifactory_cleanup.sh --url https://artifactory.example.com --repo libs-release --days 90
  bash/artifactory_cleanup.sh --repo libs-snapshot --days 30 --apply
EOF
}

BASE_URL="${ARTIFACTORY_URL:-}"
REPO=""
DAYS=""
PATH_PREFIX=""
APPLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) BASE_URL="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --days) DAYS="${2:-}"; shift 2 ;;
    --path-prefix) PATH_PREFIX="${2:-}"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$BASE_URL" ]]; then
  echo "Artifactory URL must be provided via --url or ARTIFACTORY_URL" >&2
  exit 2
fi
if [[ -z "$REPO" ]]; then
  echo "--repo is required" >&2
  exit 2
fi
if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "--days must be a non-negative integer" >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 3
fi
if ! command -v date >/dev/null 2>&1; then
  echo "date is required" >&2
  exit 3
fi

# GNU date format expected on Linux.
ISO_CUTOFF="$(date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)"

AQL_CRITERIA="{\"repo\":\"$REPO\",\"type\":\"file\",\"modified\":{\"\$before\":\"$ISO_CUTOFF\"}}"
if [[ -n "$PATH_PREFIX" ]]; then
  AQL_CRITERIA="$(jq -c --argjson c "$AQL_CRITERIA" --arg p "$PATH_PREFIX" '$c + {path:{"$match":($p + "*")}}' <<< '{}')"
else
  AQL_CRITERIA="$(jq -c --argjson c "$AQL_CRITERIA" '$c' <<< '{}')"
fi
AQL="items.find(${AQL_CRITERIA}).include(\"repo\",\"path\",\"name\",\"modified\")"

CURL_HEADERS=(-H "Content-Type: text/plain")
API_KEY="${X_JFROG_ART_API:-${ARTIFACTORY_API_KEY:-${X-JFrog-Art-Api:-}}}"
if [[ -n "$API_KEY" ]]; then
  CURL_HEADERS+=(-H "X-JFrog-Art-Api: $API_KEY")
elif [[ -n "${ART_USER:-}" && -n "${ART_PASSWORD:-}" ]]; then
  CURL_HEADERS+=(--user "${ART_USER}:${ART_PASSWORD}")
else
  echo "Warning: no API key or basic auth provided; requests may be unauthenticated" >&2
fi

SEARCH_URL="${BASE_URL%/}/api/search/aql"
resp_file="$(mktemp)"
http_code="$(curl -sS -o "$resp_file" -w '%{http_code}' -X POST "$SEARCH_URL" "${CURL_HEADERS[@]}" --data "$AQL")"
if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  echo "AQL query failed: HTTP $http_code" >&2
  cat "$resp_file" >&2 || true
  rm -f "$resp_file"
  exit 3
fi

count="$(jq '.results | length' "$resp_file")"
if [[ "$count" -eq 0 ]]; then
  echo "No artifacts found matching criteria."
  rm -f "$resp_file"
  exit 0
fi

echo "Found $count artifacts older than $DAYS days in repo $REPO."
jq -r '.results[] | if (.path // "") == "" then "\(.repo)/\(.name)  (modified: \(.modified // "unknown"))" else "\(.repo)/\(.path)/\(.name)  (modified: \(.modified // "unknown"))" end' "$resp_file"

if [[ "$APPLY" == false ]]; then
  echo "Dry-run; no deletions performed. Re-run with --apply to delete."
  rm -f "$resp_file"
  exit 0
fi

errors=0
while IFS=$'\t' read -r repo path name; do
  [[ -z "$repo" || -z "$name" ]] && continue

  if [[ -n "$path" && "$path" != "." ]]; then
    delete_url="${BASE_URL%/}/${repo}/${path}/${name}"
    display="${repo}/${path}/${name}"
  else
    delete_url="${BASE_URL%/}/${repo}/${name}"
    display="${repo}/${name}"
  fi

  code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$delete_url" "${CURL_HEADERS[@]}")" || code="000"
  if [[ "$code" -ge 200 && "$code" -lt 300 ]]; then
    echo "Deleted: $display"
  else
    echo "Failed to delete $display: HTTP $code" >&2
    errors=$((errors + 1))
  fi
done < <(jq -r '.results[] | [.repo, (.path // ""), .name] | @tsv' "$resp_file")

rm -f "$resp_file"

if [[ "$errors" -gt 0 ]]; then
  echo "Completed with $errors errors" >&2
  exit 4
fi

echo "Deletion completed successfully."
exit 0
