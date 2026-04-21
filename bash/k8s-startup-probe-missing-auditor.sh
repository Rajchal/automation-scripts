#!/usr/bin/env bash
set -euo pipefail

# k8s-startup-probe-missing-auditor.sh
# Detect workloads missing startupProbe in container definitions.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Scans pods and workload controllers for containers without startupProbe.
  - Useful for finding apps that may stall startup indefinitely without proper probing.

Examples:
  bash/k8s-startup-probe-missing-auditor.sh
  bash/k8s-startup-probe-missing-auditor.sh --output json
  bash/k8s-startup-probe-missing-auditor.sh --output json --no-fail
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

resources=(pods deployments daemonsets statefulsets replicasets replicationcontrollers jobs cronjobs)
all_json='{"items":[]}'
for res in "${resources[@]}"; do
  chunk="$(kubectl get "$res" --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
  all_json="$(jq -s '.[0] * {items:(.[0].items + .[1].items)}' <(echo "$all_json") <(echo "$chunk"))"
done

findings="$(jq -c '
  .items[]?
  | .spec.template.spec? as $podSpec // .spec
  | {kind:.kind, namespace:.metadata.namespace, name:.metadata.name, containers:($podSpec.containers // []), initContainers:($podSpec.initContainers // [])}
  | .containers += .initContainers
  | .containers[]?
  | select(.startupProbe == null)
  | {kind:.kind, namespace:.namespace, name:.name, container:.name}
' <<< "$all_json")"

result="$(jq -n --argjson findings "[$findings]" '{missing_startup_probe:$findings}')"
count="$(jq '.missing_startup_probe | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No missing startupProbe findings found."
  else
    echo "Containers missing startupProbe (count=$count):"
    jq -r '.missing_startup_probe[] | "- \(.kind) \(.namespace)/\(.name) container=\(.container)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
