#!/usr/bin/env bash
set -euo pipefail

# k8s-resource-request-limit-auditor.sh
# Detect containers in workloads where CPU/Memory limits are lower than requests.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans Deployments, StatefulSets, DaemonSets, ReplicaSets, ReplicationControllers, Jobs, CronJobs, and Pods.
  - Flags containers/initContainers if limit < request for CPU or memory.

Examples:
  bash/k8s-resource-request-limit-auditor.sh
  bash/k8s-resource-request-limit-auditor.sh --output json
  bash/k8s-resource-request-limit-auditor.sh --output json --no-fail
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

resources_json="$(kubectl get deploy,sts,ds,rs,rc,jobs,cronjobs,pods --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"

findings="$(jq -c '
  .items[]?
  | {kind:.kind, namespace:.metadata.namespace, name:.metadata.name, podSpec:(.spec.template.spec // .spec)}
  | .podSpec as $spec
  | ($spec.containers // [] + $spec.initContainers // []) as $containers
  | $containers[]?
  | {kind:.kind, namespace:.namespace, workload:.name, container:.name,
      cpu_request:(.resources.requests.cpu // ""), cpu_limit:(.resources.limits.cpu // ""),
      mem_request:(.resources.requests.memory // ""), mem_limit:(.resources.limits.memory // "")}
  | select((.cpu_request != "" and .cpu_limit != "" and (.cpu_limit | sub("m$"; "") | tonumber) < (.cpu_request | sub("m$"; "") | tonumber))
      or (.mem_request != "" and .mem_limit != "" and (.mem_limit | sub("Ki$|Mi$|Gi$"; "") | tonumber) < (.mem_request | sub("Ki$|Mi$|Gi$"; "") | tonumber)))
' <<< "$resources_json")"

result="$(jq -n --argjson findings "[$findings]" '{request_above_limit:$findings}')"
count="$(jq '.request_above_limit | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No containers with limit less than request detected."
  else
    echo "Containers where limit < request found (count=$count):"
    jq -r '.request_above_limit[] | "- \(.kind) \(.namespace)/\(.workload) container=\(.container) cpu=\(.cpu_request)/\(.cpu_limit) mem=\(.mem_request)/\(.mem_limit)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
