#!/usr/bin/env bash
set -euo pipefail

# k8s-allow-privilege-escalation-auditor.sh
# Report containers where securityContext.allowPrivilegeEscalation is true or unset.

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
  - Flags when allowPrivilegeEscalation=true OR not explicitly set.
  - This is a conservative hardening-oriented policy.

Examples:
  bash/k8s-allow-privilege-escalation-auditor.sh
  bash/k8s-allow-privilege-escalation-auditor.sh --namespace production
  bash/k8s-allow-privilege-escalation-auditor.sh --output json --no-fail
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
    | .metadata.namespace as $ns
    | .metadata.name as $pod
    | [
        ((.spec.containers // [])[]? | {container_type:"container", name:(.name // "unknown"), ape:(.securityContext.allowPrivilegeEscalation // null)}),
        ((.spec.initContainers // [])[]? | {container_type:"initContainer", name:(.name // "unknown"), ape:(.securityContext.allowPrivilegeEscalation // null)})
      ]
    | .[]
    | select((.ape == true) or (.ape == null))
    | {
        namespace: $ns,
        pod: $pod,
        container_type: .container_type,
        container_name: .name,
        allow_privilege_escalation: (.ape // "unset"),
        issue: "AllowPrivilegeEscalationEnabledOrUnset"
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
    --argjson findings "$findings_json" \
    '{scope:$scope, context:$context, selector:$selector, pod_count:$pod_count, allow_privilege_escalation_findings:$findings}'
else
  echo "K8s AllowPrivilegeEscalation Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Pods checked: $pod_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "No containers with allowPrivilegeEscalation enabled/unset were found."
  else
    echo "Containers with allowPrivilegeEscalation enabled/unset: $finding_count"
    jq -r '.[] | "- \(.namespace)/\(.pod) type=\(.container_type) container=\(.container_name) allowPrivilegeEscalation=\(.allow_privilege_escalation)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
