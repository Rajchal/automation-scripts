#!/usr/bin/env bash
set -euo pipefail

# k8s-ingress-backend-auditor.sh
# Report Ingress rules whose backend Service does not exist in the same namespace.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json]

Options:
  --namespace NS      Check only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter Ingresses (default: none)
  --output FORMAT     Output format: text (default) or json
  -h, --help          Show this help message

Examples:
  bash/k8s-ingress-backend-auditor.sh
  bash/k8s-ingress-backend-auditor.sh --namespace production
  bash/k8s-ingress-backend-auditor.sh --output json
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

ing_json="$(${KUBECTL[@]} get ingress "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"
svc_json="$(${KUBECTL[@]} get svc "${ns_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

issues_json="$(jq -c --argjson svcs "$svc_json" '
  def svc_exists($ns; $name):
    any($svcs.items[]?; .metadata.namespace == $ns and .metadata.name == $name);

  [
    .items[]?
    | .metadata.namespace as $ns
    | .metadata.name as $ing
    | [
        (
          .spec.defaultBackend.service.name? as $svc
          | select($svc != null and $svc != "")
          | {
              namespace: $ns,
              ingress: $ing,
              host: "*",
              path: "/",
              backend_service: $svc,
              issue: (if svc_exists($ns; $svc) then "ok" else "ServiceNotFound" end)
            }
        ),
        (
          .spec.rules[]?
          | .host as $host
          | .http.paths[]?
          | .path as $path
          | .backend.service.name? as $svc
          | select($svc != null and $svc != "")
          | {
              namespace: $ns,
              ingress: $ing,
              host: ($host // "*"),
              path: ($path // "/"),
              backend_service: $svc,
              issue: (if svc_exists($ns; $svc) then "ok" else "ServiceNotFound" end)
            }
        )
      ]
    | .[]
    | select(.issue != "ok")
  ]
  | unique_by(.namespace, .ingress, .host, .path, .backend_service)
' <<< "$ing_json")"

issue_count="$(jq 'length' <<< "$issues_json")"
ingress_count="$(jq '.items | length' <<< "$ing_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson ingress_count "$ingress_count" \
    --argjson issues "$issues_json" \
    '{scope:$scope, context:$context, selector:$selector, ingress_count:$ingress_count, ingress_backend_issues:$issues}'
else
  echo "K8s Ingress Backend Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Ingresses checked: $ingress_count"
  echo ""

  if [[ "$issue_count" -eq 0 ]]; then
    echo "No missing backend Services were found for checked Ingresses."
  else
    echo "Ingress backend issues: $issue_count"
    jq -r '.[] | "- \(.namespace)/\(.ingress) host=\(.host) path=\(.path) backend=\(.backend_service) issue=\(.issue)"' <<< "$issues_json"
  fi
fi

if [[ "$issue_count" -gt 0 ]]; then
  exit 1
fi

exit 0
