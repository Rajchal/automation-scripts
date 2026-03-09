#!/usr/bin/env bash
set -euo pipefail

# k8s-service-endpoint-auditor.sh
# Report selector-based Services that currently have no ready endpoints.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json]

Options:
  --namespace NS      Check only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter Services (default: none)
  --output FORMAT     Output format: text (default) or json
  -h, --help          Show this help message

Examples:
  bash/k8s-service-endpoint-auditor.sh
  bash/k8s-service-endpoint-auditor.sh --namespace production
  bash/k8s-service-endpoint-auditor.sh --output json
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

services_json="$(${KUBECTL[@]} get svc "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"
endpoints_json="$(${KUBECTL[@]} get endpoints "${ns_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

missing_json="$(jq -c --argjson eps "$endpoints_json" '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $name
    | (.spec.selector // {}) as $selector
    | select(($selector | length) > 0)
    | ($eps.items[]? | select(.metadata.namespace == $ns and .metadata.name == $name)) as $ep
    | {
        namespace: $ns,
        service: $name,
        type: (.spec.type // "ClusterIP"),
        selector: $selector,
        ready_addresses: (([$ep.subsets[]?.addresses[]?] | length) // 0),
        not_ready_addresses: (([$ep.subsets[]?.notReadyAddresses[]?] | length) // 0)
      }
    | select(.ready_addresses == 0)
  ]
' <<< "$services_json")"

missing_count="$(jq 'length' <<< "$missing_json")"
service_count="$(jq '.items | length' <<< "$services_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson service_count "$service_count" \
    --argjson missing "$missing_json" \
    '{scope:$scope, context:$context, selector:$selector, service_count:$service_count, services_without_ready_endpoints:$missing}'
else
  echo "K8s Service Endpoint Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Services checked: $service_count"
  echo ""

  if [[ "$missing_count" -eq 0 ]]; then
    echo "No selector-based Services without ready endpoints were found."
  else
    echo "Services without ready endpoints: $missing_count"
    jq -r '.[] | "- \(.namespace)/\(.service) type=\(.type) ready=\(.ready_addresses) notReady=\(.not_ready_addresses)"' <<< "$missing_json"
  fi
fi

if [[ "$missing_count" -gt 0 ]]; then
  exit 1
fi

exit 0
