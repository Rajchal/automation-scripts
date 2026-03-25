#!/usr/bin/env bash
set -euo pipefail

# k8s-pod-security-policy-auditor.sh
# Report clusters with PodSecurityPolicy objects and their usage by roles/clusterroles.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Lists PSP objects and role bindings that reference them (rbac.authorization.k8s.io/psp). 
  - Useful to detect cluster security boundaries that may be too permissive.

Examples:
  bash/k8s-pod-security-policy-auditor.sh
  bash/k8s-pod-security-policy-auditor.sh --output json
  bash/k8s-pod-security-policy-auditor.sh --output json --no-fail
EOF
}

OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --no-fail) NO_FAIL=true; shift ;;
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

psps_json="$(kubectl get psp --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
bindings_json="$(kubectl get rolebinding,clusterrolebinding --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"

psps="$(jq -c '.items[]? | {name:.metadata.name, namespace:(.metadata.namespace // "cluster"), privileged:.privileged, allowPrivilegeEscalation:(.allowPrivilegeEscalation // false), runAsUser:.runAsUser.rule, fsGroup:.fsGroup.rule, seLinux:.seLinux.rule, readOnlyRootFilesystem:.readOnlyRootFilesystem}' <<< "$psps_json")"

psp_refs="$(jq -c '.items[]? | .metadata.name as $name | .kind as $kind | .metadata.namespace as $namespace | .roleRef as $rr | .subjects[]? | select(.kind=="ServiceAccount" or .kind=="User" or .kind=="Group") | select(.name == "podsecuritypolicy" or .apiGroup == "extensions" or .apiGroup == "policy") | . as $subject | {binding_name:$name, binding_kind:$kind, binding_ns:$namespace, roleRef:$rr, subject:$subject, psp_ref:(.name // "")}' <<< "$bindings_json")"

combined="$(jq -n --argjson psps "[$psps]" --argjson refs "[$psp_refs]" '{pod_security_policies:$psps, psp_references:$refs}')"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$combined" | jq '.'
  retval=0
else
  echo "PodSecurityPolicy Objects:"; echo "----------------------"
  jq -r '.pod_security_policies[]? | "- name=\(.name) ns=\(.namespace) privileged=\(.privileged) allowPrivilegeEscalation=\(.allowPrivilegeEscalation) runAsUser=\(.runAsUser) fsGroup=\(.fsGroup) seLinux=\(.seLinux) roRootFS=\(.readOnlyRootFilesystem)"' <<< "$combined"
  echo ""
  echo "PSP References in RBAC Bindings:"; echo "--------------------------------"
  jq -r '.psp_references[]? | "- binding=\(.binding_kind)/\(.binding_ns)/\(.binding_name) roleRef=\(.roleRef.name) subject=\(.subject.kind):\(.subject.name) psp=\(.psp_ref)"' <<< "$combined"
  retval=0
fi

if [[ "$NO_FAIL" == false && $(jq '.psp_references | length' <<< "$combined") -gt 0 ]]; then
  retval=1
fi

exit $retval
