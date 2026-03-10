#!/usr/bin/env bash
set -euo pipefail

# k8s-job-failure-auditor.sh
# Report failed Jobs and CronJobs that are suspended or whose last run failed.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json]

Options:
  --namespace NS      Check only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter Jobs/CronJobs (default: none)
  --output FORMAT     Output format: text (default) or json
  -h, --help          Show this help message

Examples:
  bash/k8s-job-failure-auditor.sh
  bash/k8s-job-failure-auditor.sh --namespace production
  bash/k8s-job-failure-auditor.sh --output json
EOF
}

NAMESPACE=""
CONTEXT=""
SELECTOR=""
OUTPUT="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --selector) SELECTOR="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "json" ]]; then
  echo "--output must be text or json" >&2
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

selector_args=()
if [[ -n "$SELECTOR" ]]; then
  selector_args=(-l "$SELECTOR")
fi

jobs_json="$(${KUBECTL[@]} get jobs "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"
cronjobs_json="$(${KUBECTL[@]} get cronjobs "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

job_issues_json="$(jq -c '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $name
    | (.spec.completions // 1) as $target
    | (.status.succeeded // 0) as $succeeded
    | (.status.failed // 0) as $failed
    | (.status.active // 0) as $active
    | {
        kind: "Job",
        namespace: $ns,
        name: $name,
        completions_target: $target,
        succeeded: $succeeded,
        failed: $failed,
        active: $active,
        issue: (
          if $failed > 0 then "FailedPods"
          elif ($succeeded < $target and $active == 0) then "NotCompletedAndInactive"
          else "Unknown"
          end
        )
      }
    | select(.failed > 0 or (.succeeded < .completions_target and .active == 0))
  ]
' <<< "$jobs_json")"

cronjob_issues_json="$(jq -c '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $name
    | (.spec.suspend // false) as $suspend
    | (.status.lastSuccessfulTime // "") as $last_success
    | (.status.lastScheduleTime // "") as $last_schedule
    | {
        kind: "CronJob",
        namespace: $ns,
        name: $name,
        suspend: $suspend,
        last_schedule_time: (if $last_schedule == "" then null else $last_schedule end),
        last_successful_time: (if $last_success == "" then null else $last_success end),
        issue: (
          if $suspend == true then "Suspended"
          elif ($last_schedule != "" and $last_success == "") then "NoSuccessfulRunRecorded"
          else "Unknown"
          end
        )
      }
    | select(.suspend == true or (.last_schedule_time != null and .last_successful_time == null))
  ]
' <<< "$cronjobs_json")"

issues_json="$(jq -c --argjson jobs "$job_issues_json" --argjson cjs "$cronjob_issues_json" '$jobs + $cjs' <<< '{}')"
issue_count="$(jq 'length' <<< "$issues_json")"
job_count="$(jq '.items | length' <<< "$jobs_json")"
cronjob_count="$(jq '.items | length' <<< "$cronjobs_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson job_count "$job_count" \
    --argjson cronjob_count "$cronjob_count" \
    --argjson issues "$issues_json" \
    '{scope:$scope, context:$context, selector:$selector, job_count:$job_count, cronjob_count:$cronjob_count, schedule_or_job_issues:$issues}'
else
  echo "K8s Job/CronJob Failure Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Jobs checked: $job_count"
  echo "CronJobs checked: $cronjob_count"
  echo ""

  if [[ "$issue_count" -eq 0 ]]; then
    echo "No failed Jobs or problematic CronJobs were found."
  else
    echo "Findings: $issue_count"
    jq -r '.[] | "- \(.kind) \(.namespace)/\(.name) issue=\(.issue)"' <<< "$issues_json"
  fi
fi

if [[ "$issue_count" -gt 0 ]]; then
  exit 1
fi

exit 0
