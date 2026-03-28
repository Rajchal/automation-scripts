#!/usr/bin/env bash
set -euo pipefail

# k8s-image-digest-auditor.sh
# Detect containers using images without digest pinning (@sha256) to improve supply-chain immutability.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Finds pods, deployments, daemonsets, statefulsets, replicaset, replicationcontroller, jobs, cronjobs 
    with containers or initContainers using image tags (instead of digest @sha256).

Examples:
  bash/k8s-image-digest-auditor.sh
  bash/k8s-image-digest-auditor.sh --output json
  bash/k8s-image-digest-auditor.sh --output json --no-fail
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

# Object types to scan
resource_types=(pods deployments daemonsets statefulsets replicasets replicationcontrollers jobs cronjobs)
all_json='{"items":[]} '
for r in "${resource_types[@]}"; do
  obj_json="$(kubectl get "$r" --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
  all_json="$(jq -s '.[0] * {items:(.[0].items + .[1].items)}' <(echo "$all_json") <(echo "$obj_json"))"
done

findings="$(jq -c '.items[]? | .spec.template.spec? as $podSpec // .spec | {kind:.kind, namespace:.metadata.namespace, name:.metadata.name, containers:($podSpec.containers // []), initContainers:($podSpec.initContainers // [])} | .containers += .initContainers | .containers[]? | select(.image | test("@sha256$") | not) | {kind:.kind, namespace:.namespace, workload:.name, container:.name, image:.image}' <<< "$all_json")"

result="$(jq -n --argjson findings "[$findings]" '{containers_without_digest:$findings}')"
count="$(jq '.containers_without_digest | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "All scanned containers use digest pinned images."
  else
    echo "Containers without digest pinning (count=$count):"
    jq -r '.containers_without_digest[] | "- \(.kind) \(.namespace)/\(.workload) container=\(.container) image=\(.image)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
