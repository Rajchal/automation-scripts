#!/usr/bin/env bash
set -euo pipefail

# k8s-apparmor-profile-auditor.sh
# Report containers that do not have explicit AppArmor profile set to RuntimeDefault/Localhost.

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
  - Checks both modern fields and legacy beta annotations for AppArmor.
  - A container is considered compliant when profile is RuntimeDefault or Localhost.

Examples:
  bash/k8s-apparmor-profile-auditor.sh
  bash/k8s-apparmor-profile-auditor.sh --namespace production
  bash/k8s-apparmor-profile-auditor.sh --output json --no-fail
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
    | . as $pod
    | .metadata.namespace as $ns
    | .metadata.name as $pod_name
    | (
        [
          ((.spec.containers // [])[]? | {container_type:"container", name:(.name // "unknown"), apparmor_field:(.securityContext.appArmorProfile.type // "")}),
          ((.spec.initContainers // [])[]? | {container_type:"initContainer", name:(.name // "unknown"), apparmor_field:(.securityContext.appArmorProfile.type // "")})
        ]
      )[]
    | .container_type as $ctype
    | .name as $cname
    | .apparmor_field as $field
    | ("container.apparmor.security.beta.kubernetes.io/" + $cname) as $ann_key
    | ($pod.metadata.annotations[$ann_key] // "") as $ann_val
    | (if $field != "" then $field else $ann_val end) as $effective
    | ("runtime/default") as $legacy_runtime
    | ("localhost/") as $legacy_local_prefix
    | select(
        ($effective != "RuntimeDefault") and
        ($effective != "Localhost") and
        ($effective != $legacy_runtime) and
        (($effective | startswith($legacy_local_prefix)) | not)
      )
    | {
        namespace: $ns,
        pod: $pod_name,
        container_type: $ctype,
        container_name: $cname,
        apparmor_field: (if $field == "" then "unset" else $field end),
        legacy_annotation: (if $ann_val == "" then "unset" else $ann_val end),
        effective_profile: (if $effective == "" then "unset" else $effective end),
        issue: "AppArmorProfileMissingOrNonCompliant"
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
    --argjson apparmor_findings "$findings_json" \
    '{scope:$scope, context:$context, selector:$selector, pod_count:$pod_count, apparmor_findings:$apparmor_findings}'
else
  echo "K8s AppArmor Profile Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Pods checked: $pod_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "All checked containers have compliant AppArmor profiles."
  else
    echo "Containers missing compliant AppArmor profile: $finding_count"
    jq -r '.[] | "- \(.namespace)/\(.pod) type=\(.container_type) container=\(.container_name) effective=\(.effective_profile) field=\(.apparmor_field) annotation=\(.legacy_annotation)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
