#!/usr/bin/env bash
set -euo pipefail

# k8s-service-exposure-auditor.sh
# Report Services that are potentially externally exposed (LoadBalancer, NodePort, or externalIPs).

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json] [--no-fail]

Options:
  --namespace NS      Audit only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter Services (default: none)
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Examples:
  bash/k8s-service-exposure-auditor.sh
  bash/k8s-service-exposure-auditor.sh --namespace production
  bash/k8s-service-exposure-auditor.sh --output json --no-fail
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

services_json="$(${KUBECTL[@]} get svc "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c '
  [
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $name
    | (.spec.type // "ClusterIP") as $type
    | (.spec.externalIPs // []) as $external_ips
    | (.spec.ports // []) as $ports
    | (.status.loadBalancer.ingress // []) as $lb_ingress
    | {
        namespace: $ns,
        service: $name,
        type: $type,
        ports: ($ports | map({port: (.port // null), protocol: (.protocol // "TCP"), node_port: (.nodePort // null)})),
        external_ips: $external_ips,
        loadbalancer_ingress: ($lb_ingress | map(.ip // .hostname // "")),
        exposure_reasons: (
          [
            (if $type == "LoadBalancer" then "TypeLoadBalancer" else empty end),
            (if $type == "NodePort" then "TypeNodePort" else empty end),
            (if ($external_ips | length) > 0 then "HasExternalIPs" else empty end)
          ]
        )
      }
    | select((.exposure_reasons | length) > 0)
  ]
' <<< "$services_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
service_count="$(jq '.items | length' <<< "$services_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson service_count "$service_count" \
    --argjson findings "$findings_json" \
    '{scope:$scope, context:$context, selector:$selector, service_count:$service_count, exposed_services:$findings}'
else
  echo "K8s Service Exposure Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Services checked: $service_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "No externally exposed Services detected by this policy."
  else
    echo "Potentially exposed Services: $finding_count"
    jq -r '.[] | "- \(.namespace)/\(.service) type=\(.type) reasons=\(.exposure_reasons | join(","))"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
