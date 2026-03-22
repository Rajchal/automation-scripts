#!/usr/bin/env bash
set -euo pipefail

# k8s-probe-missing-auditor.sh
# Report containers lacking liveness or readiness probes.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--kind deployment,statefulset,daemonset,replicaset,pod] [--output text|json] [--no-fail]

Options:
  --namespace NS      Audit one namespace (default all)
  --context CONTEXT   Kubernetes context
  --selector S        Label selector
  --kind LIST         Comma-separated resources to scan (default all)
  --output FORMAT     text or json
  --no-fail           Exit 0 even when findings exist
  -h, --help          Show help

Examples:
  bash/k8s-probe-missing-auditor.sh
  bash/k8s-probe-missing-auditor.sh --namespace production --kind deployment,statefulset
  bash/k8s-probe-missing-auditor.sh --output json --no-fail
EOF
}

NAMESPACE=""
CONTEXT=""
SELECTOR=""
KINDS="deployment,statefulset,daemonset,replicaset,pod"
OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --selector) SELECTOR="${2:-}"; shift 2 ;;
    --kind) KINDS="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --no-fail) NO_FAIL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "json" ]]; then
  echo "--output must be text or json" >&2; exit 2
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2; exit 3
fi

KUBECTL=(kubectl)
if [[ -n "$CONTEXT" ]]; then KUBECTL+=(--context "$CONTEXT"); fi
ns_args=(); [[ -n "$NAMESPACE" ]] && ns_args=(-n "$NAMESPACE") || ns_args=(--all-namespaces)
selector_args=(); [[ -n "$SELECTOR" ]] && selector_args=(-l "$SELECTOR")

workloads_json="$(${KUBECTL[@]} get ${KINDS} "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .kind as $kind
    | .metadata.name as $name
    | .spec.template.spec? as $spec
    | (.spec.containers // []) as $containers
    | (.spec.initContainers // []) as $init_containers
    | ($containers + $init_containers)[]?
    | .name as $container
    | .livenessProbe as $liveness
    | .readinessProbe as $readiness
    | select(($liveness == null) or ($readiness == null))
    | {
        namespace:$ns,
        kind:$kind,
        workload:$name,
        container:$container,
        livenessProbe: (if $liveness == null then "missing" else "present" end),
        readinessProbe: (if $readiness == null then "missing" else "present" end),
        issue:"MissingProbe"
      }
  ]
' <<< "$workloads_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
workload_count="$(jq '.items | length' <<< "$workloads_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n --arg scope "${NAMESPACE:-all}" --arg context "${CONTEXT:-current}" --arg selector "${SELECTOR:-none}" --arg kinds "$KINDS" --argjson count "$workload_count" --argjson findings "$findings_json" '{scope:$scope, context:$context, selector:$selector, kinds:$kinds, workload_count:$count, findings:$findings}'
else
  echo "K8s Probe Missing Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Kinds: $KINDS"
  echo "Workloads scanned: $workload_count"
  echo ""
  if [[ "$finding_count" -eq 0 ]]; then
    echo "All containers have both liveness and readiness probes.";
  else
    echo "Containers missing probes: $finding_count"
    jq -r '.[] | "- [\(.kind)] \(.namespace)/\(.workload) container=\(.container) liveness=\(.livenessProbe) readiness=\(.readinessProbe)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then exit 1; fi
exit 0
