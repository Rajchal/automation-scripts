#!/usr/bin/env bash
set -euo pipefail

# k8s-pod-restart-spike-auditor.sh
# Detect pods with high container restart counts and optionally annotate them.

usage() {
  cat <<'EOF'
Usage: $0 [--namespace NS] [--context CONTEXT] [--restart-threshold N] [--min-age-minutes N]
          [--annotate] [--no-dry-run] [--output text|json] [--no-fail]

Options:
  --namespace NS           Audit one namespace (default: all namespaces)
  --context CONTEXT        Kubernetes context to use
  --restart-threshold N    Minimum total restarts per pod to flag (default: 5)
  --min-age-minutes N      Ignore very new pods younger than this age (default: 10)
  --annotate               Annotate flagged pods with audit metadata
  --no-dry-run             Apply annotations when used with --annotate (default: dry-run)
  --output FORMAT          text (default) or json
  --no-fail                Exit 0 even when spikes are found
  -h, --help               Show this help

Notes:
  - Pod restart count is sum of .status.containerStatuses[].restartCount.
  - Pod age is based on .status.startTime (UTC) and current time.

Examples:
  bash/k8s-pod-restart-spike-auditor.sh
  bash/k8s-pod-restart-spike-auditor.sh --namespace production --restart-threshold 8
  bash/k8s-pod-restart-spike-auditor.sh --annotate --no-dry-run
EOF
}

NAMESPACE=""
CONTEXT=""
RESTART_THRESHOLD=5
MIN_AGE_MINUTES=10
ANNOTATE=false
DRY_RUN=true
OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --restart-threshold) RESTART_THRESHOLD="${2:-}"; shift 2 ;;
    --min-age-minutes) MIN_AGE_MINUTES="${2:-}"; shift 2 ;;
    --annotate) ANNOTATE=true; shift ;;
    --no-dry-run) DRY_RUN=false; shift ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --no-fail) NO_FAIL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "json" ]]; then
  echo "--output must be text or json" >&2
  exit 2
fi
if ! [[ "$RESTART_THRESHOLD" =~ ^[0-9]+$ ]]; then
  echo "--restart-threshold must be a non-negative integer" >&2
  exit 2
fi
if ! [[ "$MIN_AGE_MINUTES" =~ ^[0-9]+$ ]]; then
  echo "--min-age-minutes must be a non-negative integer" >&2
  exit 2
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
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

KUBECTL=(kubectl)
if [[ -n "$CONTEXT" ]]; then
  KUBECTL+=(--context "$CONTEXT")
fi

ns_args=()
if [[ -n "$NAMESPACE" ]]; then
  ns_args=(-n "$NAMESPACE")
else
  ns_args=(--all-namespaces)
fi

pods_json="$(${KUBECTL[@]} get pods "${ns_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"
now_epoch="$(date +%s)"

pod_count="$(jq '.items | length' <<< "$pods_json")"

# Build result rows from kubectl JSON once to avoid repeated API calls.
spikes_tsv="$({
  jq -r --argjson now "$now_epoch" '
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $name
    | (.status.startTime // "") as $start
    | ((.status.containerStatuses // []) | map(.restartCount // 0) | add // 0) as $restarts
    | (if $start == "" then -1 else ((($start | fromdateiso8601) // 0)) end) as $start_epoch
    | (if $start_epoch < 0 then -1 else (($now - $start_epoch) / 60 | floor) end) as $age_minutes
    | "\($ns)\t\($name)\t\($restarts)\t\($age_minutes)\t\($start)"
  ' <<< "$pods_json"
} || true)"

flagged_json="[]"
while IFS=$'\t' read -r ns name restarts age_minutes start_time; do
  [[ -z "${ns:-}" || -z "${name:-}" ]] && continue

  if [[ "$age_minutes" -lt 0 ]]; then
    # If startTime is unavailable, skip age-based filter and only use restart threshold.
    if [[ "$restarts" -lt "$RESTART_THRESHOLD" ]]; then
      continue
    fi
  else
    if [[ "$restarts" -lt "$RESTART_THRESHOLD" || "$age_minutes" -lt "$MIN_AGE_MINUTES" ]]; then
      continue
    fi
  fi

  action="none"
  if [[ "$ANNOTATE" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      action="would-annotate"
    else
      stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      ${KUBECTL[@]} annotate pod "$name" -n "$ns" \
        auditor.dev/restart-spike=true \
        auditor.dev/restart-count="$restarts" \
        auditor.dev/restart-audited-at="$stamp" \
        --overwrite >/dev/null
      action="annotated"
    fi
  fi

  flagged_json="$(jq -c \
    --arg ns "$ns" \
    --arg name "$name" \
    --argjson restarts "$restarts" \
    --argjson age_minutes "$age_minutes" \
    --arg start_time "$start_time" \
    --arg action "$action" \
    '. + [{namespace:$ns, name:$name, restarts:$restarts, age_minutes:$age_minutes, start_time:$start_time, action:$action}]' \
    <<< "$flagged_json")"
done <<< "$spikes_tsv"

flagged_count="$(jq 'length' <<< "$flagged_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --argjson restart_threshold "$RESTART_THRESHOLD" \
    --argjson min_age_minutes "$MIN_AGE_MINUTES" \
    --argjson pod_count "$pod_count" \
    --arg annotate "$ANNOTATE" \
    --arg dry_run "$DRY_RUN" \
    --argjson flagged "$flagged_json" \
    '{scope:$scope, context:$context, restart_threshold:$restart_threshold, min_age_minutes:$min_age_minutes, pod_count:$pod_count, annotate:($annotate=="true"), dry_run:($dry_run=="true"), flagged_pods:$flagged}'
else
  echo "K8s Pod Restart Spike Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Restart threshold: $RESTART_THRESHOLD"
  echo "Minimum pod age (minutes): $MIN_AGE_MINUTES"
  echo "Pods scanned: $pod_count"
  echo "Annotate mode: $ANNOTATE"
  echo "Dry run: $DRY_RUN"
  echo ""

  if [[ "$flagged_count" -eq 0 ]]; then
    echo "No restart spikes detected."
  else
    echo "Flagged pods: $flagged_count"
    jq -r '.[] | "- \(.namespace)/\(.name) restarts=\(.restarts) age_minutes=\(.age_minutes) action=\(.action)"' <<< "$flagged_json"
  fi
fi

if [[ "$flagged_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
