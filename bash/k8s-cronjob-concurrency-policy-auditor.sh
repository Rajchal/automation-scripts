#!/usr/bin/env bash
set -euo pipefail

# k8s-cronjob-concurrency-policy-auditor.sh
# Detect CronJobs with missing or permissive concurrencyPolicy (defaults to "Allow").

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Checks CronJobs where concurrencyPolicy is missing, "Allow", or "Replace".
  - For strict safety, recommends "Forbid".

Examples:
  bash/k8s-cronjob-concurrency-policy-auditor.sh
  bash/k8s-cronjob-concurrency-policy-auditor.sh --output json
  bash/k8s-cronjob-concurrency-policy-auditor.sh --output json --no-fail
EOF
}

OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
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
findings="$(jq -c '.items[]? | {namespace:.metadata.namespace, name:.metadata.name, concurrencyPolicy:(.spec.concurrencyPolicy // "Allow"), suspend:(.spec.suspend // false)} | select(.concurrencyPolicy == "Allow" or .concurrencyPolicy == "Replace" or .concurrencyPolicy == "" or .concurrencyPolicy == null)' <<< "$cronjobs_json")"
result="$(jq -n --argjson findings "[$findings]" '{cronjobs_weak_concurrency_policy:$findings}')"
count="$(jq '.cronjobs_weak_concurrency_policy | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "All CronJobs use Forbid concurrencyPolicy."
  else
    echo "CronJobs with potentially weak concurrencyPolicy (count=$count):"
    jq -r '.cronjobs_weak_concurrency_policy[] | "- \(.namespace)/\(.name) concurrencyPolicy=\(.concurrencyPolicy) suspend=\(.suspend)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
