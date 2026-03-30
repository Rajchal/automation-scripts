#!/usr/bin/env bash
set -euo pipefail

# k8s-nonterminating-pod-auditor.sh
# Detect pods stuck in Pending/ContainerCreating for long durations.

usage() {
  cat <<EOF
Usage: $0 [--threshold-minutes MINUTES] [--output text|json] [--no-fail]

Options:
  --threshold-minutes MINUTES  default 30
  --output FORMAT              text (default) or json
  --no-fail                    Exit 0 even when findings are present
  -h, --help                   Show this help

Notes:
  - Flags pods where phase is Pending or '/containerCreating/' is in the reason for more than threshold.
  - Uses pod start time and conditions where possible.

Examples:
  bash/k8s-nonterminating-pod-auditor.sh
  bash/k8s-nonterminating-pod-auditor.sh --threshold-minutes 60 --output json
  bash/k8s-nonterminating-pod-auditor.sh --threshold-minutes 60 --output json --no-fail
EOF
}

THRESHOLD=30
OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold-minutes)
      THRESHOLD="${2:-}"; shift 2
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

if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
  echo "--threshold-minutes must be a positive integer" >&2
  exit 2
fi

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "json" ]]; then
  echo "--output must be text or json" >&2
  exit 2
fi

for cmd in kubectl jq date; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required" >&2
    exit 3
  fi
done

pods_json="$(kubectl get pods --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
now_ts=$(date -u +%s)
threshold_seconds=$((THRESHOLD * 60))

findings="$(jq -c --arg now "$now_ts" --argjson threshold "$threshold_seconds" '
  .items[]?
  | select(.status.phase == "Pending" or (.status.containerStatuses[]? // [] | .state.waiting.reason? | test("ContainerCreating|CrashLoopBackOff|ErrImagePull|ImagePullBackOff") ))
  | .metadata as $m | .status as $s
  | {namespace:$m.namespace, name:$m.name, phase:$s.phase, startedAt:$s.startTime, reason:(($s.containerStatuses[]? // [] | .state.waiting.reason // "") | tostring), ageSeconds:((now | tonumber) - ((($m.creationTimestamp // $s.startTime // "1970-01-01T00:00:00Z") | sub("Z$";"") | strptime("%Y-%m-%dT%H:%M:%S") | mktime))))}
  | select(.ageSeconds >= threshold)
' <<< "$pods_json")"

result="$(jq -n --argjson findings "[$findings]" '{nonterminating_pods:$findings}')"
count="$(jq '.nonterminating_pods | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No nonterminating pods found above threshold of $THRESHOLD minutes."
  else
    echo "Nonterminating pods above threshold ($THRESHOLD minutes) count=$count:"
    jq -r '.nonterminating_pods[] | "- \(.namespace)/\(.name) phase=\(.phase) reason=\(.reason) ageSec=\(.ageSeconds)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
