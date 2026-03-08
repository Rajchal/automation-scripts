#!/usr/bin/env bash
set -euo pipefail

# k8s-image-tag-auditor.sh
# Audits Kubernetes workloads for unpinned container images (:latest or no tag).

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--kinds LIST] [--output text|json]

Options:
  --namespace NS       Scan one namespace only (default: all namespaces)
  --context CONTEXT    Kubernetes context to use
  --selector S         Label selector to filter workloads
  --kinds LIST         Comma-separated kinds: deployment,statefulset,daemonset (default: all)
  --output FORMAT      text (default) or json
  -h, --help           Show help

Examples:
  # Audit all workloads in all namespaces
  bash/k8s-image-tag-auditor.sh

  # Audit only production deployments
  bash/k8s-image-tag-auditor.sh --namespace production --kinds deployment

  # JSON output for CI usage
  bash/k8s-image-tag-auditor.sh --output json
EOF
}

NAMESPACE=""
CONTEXT=""
SELECTOR=""
KINDS="deployment,statefulset,daemonset"
OUTPUT="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --selector) SELECTOR="${2:-}"; shift 2 ;;
    --kinds) KINDS="${2:-}"; shift 2 ;;
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

# Normalize kinds from singular to kubectl resource names.
resource_kinds="$(tr ',' '\n' <<< "$KINDS" | sed 's/[[:space:]]//g' | sed '/^$/d' | awk '
  {
    if ($0 == "deployment" || $0 == "deploy") print "deploy";
    else if ($0 == "statefulset" || $0 == "sts") print "statefulset";
    else if ($0 == "daemonset" || $0 == "ds") print "daemonset";
    else print "INVALID:"$0;
  }
' | sort -u | paste -sd, -)"

if grep -q "INVALID:" <<< "$resource_kinds"; then
  echo "Invalid --kinds value. Allowed: deployment,statefulset,daemonset" >&2
  exit 2
fi

workloads_json="$(${KUBECTL[@]} get "$resource_kinds" "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

total_workloads="$(jq '.items | length' <<< "$workloads_json")"

findings_json="$(jq -c '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .kind as $kind
    | .metadata.name as $name
    | (.spec.template.spec.containers // [])[]?
    | .name as $container
    | .image as $image
    | if ($image | test("@sha256:")) then
        empty
      elif ($image | test(":") | not) then
        {namespace:$ns, kind:$kind, workload:$name, container:$container, image:$image, issue:"untagged_image"}
      elif ($image | test(":latest$")) then
        {namespace:$ns, kind:$kind, workload:$name, container:$container, image:$image, issue:"latest_tag"}
      else
        empty
      end
  ]
' <<< "$workloads_json")"

finding_count="$(jq 'length' <<< "$findings_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --arg kinds "$resource_kinds" \
    --argjson workload_count "$total_workloads" \
    --argjson findings "$findings_json" \
    '{scope:$scope, context:$context, selector:$selector, kinds:$kinds, workload_count:$workload_count, findings:$findings}'
else
  echo "K8s Image Tag Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Kinds: $resource_kinds"
  echo "Selector: ${SELECTOR:-none}"
  echo "Workloads scanned: $total_workloads"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "No unpinned image tags found."
  else
    echo "Findings: $finding_count"
    jq -r '.[] | "- [\(.issue)] \(.namespace)/\(.kind)/\(.workload) container=\(.container) image=\(.image)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 ]]; then
  exit 1
fi

exit 0
