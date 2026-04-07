#!/usr/bin/env bash
set -euo pipefail

# k8s-image-registry-auditor.sh
# Detect workloads using container images from registries outside allowed prefixes.

usage() {
  cat <<EOF
Usage: $0 [--allowed-registry-prefixes PREFIX1,PREFIX2,...] [--output text|json] [--no-fail]

Options:
  --allowed-registry-prefixes  Comma-separated allowed registry prefixes (default: docker.io/,k8s.gcr.io/,registry.k8s.io/,gcr.io/,quay.io/,ghcr.io/)
  --output FORMAT             text (default) or json
  --no-fail                   Exit 0 even when findings are present
  -h, --help                  Show this help

Notes:
  - Scans pods and workload controllers for container images from unapproved registries.
  - Useful to enforce registry policy for trusted image sources.

Examples:
  bash/k8s-image-registry-auditor.sh
  bash/k8s-image-registry-auditor.sh --allowed-registry-prefixes docker.io/,gcr.io/ --output json
  bash/k8s-image-registry-auditor.sh --output json --no-fail
EOF
}

OUTPUT="text"
NO_FAIL=false
ALLOWED_REGISTRIES="docker.io/,k8s.gcr.io/,registry.k8s.io/,gcr.io/,quay.io/,ghcr.io/"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allowed-registry-prefixes)
      ALLOWED_REGISTRIES="${2:-}"; shift 2
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

IFS=',' read -r -a prefixes <<< "$ALLOWED_REGISTRIES"

resources=(pods deployments daemonsets statefulsets replicasets replicationcontrollers jobs cronjobs)
all_json='{"items":[]}'
for res in "${resources[@]}"; do
  chunk="$(kubectl get "$res" --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
  all_json="$(jq -s '.[0] * {items:(.[0].items + .[1].items)}' <(echo "$all_json") <(echo "$chunk"))"
done

findings="$(jq -c --argjson prefixes "$(printf '%s
' "${prefixes[@]}" | jq -R . | jq -s .)" '
  .items[]?
  | .spec.template.spec? as $podSpec // .spec
  | .containers[]? as $c
  | ($c.image // "") as $img
  | select([ $prefixes[]? | startswith($img) ] | any == false)
  | {kind:.kind, namespace:.metadata.namespace, name:.metadata.name, container:$c.name, image:$img}
' <<< "$all_json")"

result="$(jq -n --argjson findings "[$findings]" '{unapproved_registry_images:$findings}')"
count="$(jq '.unapproved_registry_images | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No container images from unapproved registries found."
  else
    echo "Container images from unapproved registries (count=$count):"
    jq -r '.unapproved_registry_images[] | "- \(.kind) \(.namespace)/\(.name) container=\(.container) image=\(.image)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
