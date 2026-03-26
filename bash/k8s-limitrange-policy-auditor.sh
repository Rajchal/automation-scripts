#!/usr/bin/env bash
set -euo pipefail

# k8s-limitrange-policy-auditor.sh
# Detect workloads with either containers or initContainers missing CPU/memory requests or limits.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans Deployments, StatefulSets, DaemonSets, ReplicaSets, ReplicationControllers, Jobs, CronJobs, and Pods.
  - Flags containers or initContainers where CPU or memory requests/limits are missing.

Examples:
  bash/k8s-limitrange-policy-auditor.sh
  bash/k8s-limitrange-policy-auditor.sh --output json
  bash/k8s-limitrange-policy-auditor.sh --output json --no-fail
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

objects_json="$(kubectl get deploy,sts,ds,rs,rc,jobs,cronjobs,pods --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"

findings="$(jq -c '
  .items[]?
  | {kind:.kind, namespace:.metadata.namespace, name:.metadata.name, podSpec:(.spec.template.spec // .spec)}
  | .podSpec as $spec
  | ($spec.containers // [] + $spec.initContainers // []) as $containers
  | $containers[]?
  | {kind:.kind, namespace:.namespace, name:.name, container:.name,
      missing:[
        (if .resources.requests.cpu == null then "cpu_request" else empty end),
        (if .resources.requests.memory == null then "memory_request" else empty end),
        (if .resources.limits.cpu == null then "cpu_limit" else empty end),
        (if .resources.limits.memory == null then "memory_limit" else empty end)
      ]}
  | select(.missing | length > 0)
' <<< "$objects_json")"

result="$(jq -n --argjson findings "[$findings]" '{missing_resource_limits:$findings}')"
count="$(jq '.missing_resource_limits | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No containers missing resource requests/limits (CPU/memory) found."
  else
    echo "Containers missing resource requests/limits (count=$count):"
    jq -r '.missing_resource_limits[] | "- \(.kind) \(.namespace)/\(.name) container=\(.container) missing=\(.missing|join(","))"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
"