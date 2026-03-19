#!/usr/bin/env bash
set -euo pipefail

# k8s-hostport-usage-auditor.sh
# Report active pods exposing hostPort mappings.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json] [--no-fail]

Options:
  --namespace NS      Audit only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter pods (default: none)
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - hostPort binds container ports directly on node interfaces.

Examples:
  bash/k8s-hostport-usage-auditor.sh
  bash/k8s-hostport-usage-auditor.sh --namespace kube-system
  bash/k8s-hostport-usage-auditor.sh --output json --no-fail
EOF
}

NAMESPACE=""
CONTEXT=""
SELECTOR=""
OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --selector) SELECTOR="${2:-}"; shift 2 ;;
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

pods_json="$(${KUBECTL[@]} get pods "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c '
  [
    .items[]?
    | select((.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed")
    | .metadata.namespace as $ns
    | .metadata.name as $pod
    | .spec.nodeName as $node
    | [
        ((.spec.containers // [])[]? | {container_type:"container", container_name:(.name // "unknown"), ports:(.ports // [])}),
        ((.spec.initContainers // [])[]? | {container_type:"initContainer", container_name:(.name // "unknown"), ports:(.ports // [])})
      ]
    | .[]
    | .container_type as $ctype
    | .container_name as $cname
    | .ports[]?
    | select((.hostPort // 0) > 0)
    | {
        namespace: $ns,
        pod: $pod,
        node: ($node // "<unassigned>"),
        container_type: $ctype,
        container_name: $cname,
        container_port: (.containerPort // 0),
        host_port: (.hostPort // 0),
        protocol: (.protocol // "TCP"),
        host_ip: (.hostIP // "all")
      }
  ]
' <<< "$pods_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
pod_count="$(jq '.items | length' <<< "$pods_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson pod_count "$pod_count" \
    --argjson hostport_findings "$findings_json" \
    '{scope:$scope, context:$context, selector:$selector, pod_count:$pod_count, hostport_findings:$hostport_findings}'
else
  echo "K8s HostPort Usage Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Pods checked: $pod_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "No active pods with hostPort mappings were found."
  else
    echo "HostPort mappings found: $finding_count"
    jq -r '.[] | "- \(.namespace)/\(.pod) node=\(.node) type=\(.container_type) container=\(.container_name) hostPort=\(.host_port) containerPort=\(.container_port) protocol=\(.protocol) hostIP=\(.host_ip)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
