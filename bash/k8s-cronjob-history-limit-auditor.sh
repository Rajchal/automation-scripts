#!/usr/bin/env bash
set -euo pipefail

# k8s-cronjob-history-limit-auditor.sh
# Detect CronJobs with missing or low successful/failed history limits.

usage() {
  cat <<EOF
Usage: $0 [--min-history-limit N] [--output text|json] [--no-fail]

Options:
  --min-history-limit N  Minimum acceptable history limit for successful and failed jobs (default: 3)
  --output FORMAT        text (default) or json
  --no-fail              Exit 0 even when findings are present
  -h, --help             Show this help

Notes:
  - Scans CronJobs for missing or too-low successfulJobsHistoryLimit and failedJobsHistoryLimit.
  - Helps ensure job history retention is configured for debugging and cleanup.

Examples:
  bash/k8s-cronjob-history-limit-auditor.sh
  bash/k8s-cronjob-history-limit-auditor.sh --min-history-limit 5 --output json
  bash/k8s-cronjob-history-limit-auditor.sh --min-history-limit 5 --output json --no-fail
EOF
}

MIN_HISTORY_LIMIT=3
OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-history-limit)
      MIN_HISTORY_LIMIT="${2:-}"; shift 2
      ;;
    --output)
      OUTPUT="${2:-}"; shift 2
      ;;
    --no-fail)
      NO_FAIL=true; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage; exit 2
      ;;
  esac
done

if ! [[ "$MIN_HISTORY_LIMIT" =~ ^[0-9]+$ ]]; then
  echo "--min-history-limit must be a positive integer" >&2
  exit 2
fi

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "json" ]]; then
  echo "--output must be text or json" >&2
  exit 2
fi

for cmd in kubectl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required" >&2
    exit 3
  fi
done

cronjobs_json="$(kubectl get cronjob --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
findings="$(jq -c --argjson min_limit "$MIN_HISTORY_LIMIT" '
  .items[]?
  | {namespace:.metadata.namespace, name:.metadata.name, successful:(.spec.successfulJobsHistoryLimit // 0), failed:(.spec.failedJobsHistoryLimit // 0)}
  | select(.successful < $min_limit or .failed < $min_limit)
' <<< "$cronjobs_json")"

result="$(jq -n --argjson findings "[$findings]" '{cronjobs_low_history_limits:$findings}')"
count="$(jq '.cronjobs_low_history_limits | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No CronJobs with missing or low history limits found."
  else
    echo "CronJobs with missing or low history limits (count=$count):"
    jq -r '.cronjobs_low_history_limits[] | "- \(.namespace)/\(.name) successful=\(.successful) failed=\(.failed)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
