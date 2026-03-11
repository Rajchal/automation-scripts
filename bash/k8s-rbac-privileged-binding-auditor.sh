#!/usr/bin/env bash
set -euo pipefail

# k8s-rbac-privileged-binding-auditor.sh
# Report RoleBindings/ClusterRoleBindings that grant high-privilege ClusterRoles.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--output text|json] [--no-fail]

Options:
  --namespace NS      Limit RoleBinding scan to one namespace (ClusterRoleBindings are always cluster-scoped)
  --context CONTEXT   Kubernetes context to use
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - High-privilege ClusterRoles checked by default: cluster-admin, admin, edit

Examples:
  bash/k8s-rbac-privileged-binding-auditor.sh
  bash/k8s-rbac-privileged-binding-auditor.sh --namespace production
  bash/k8s-rbac-privileged-binding-auditor.sh --output json --no-fail
EOF
}

NAMESPACE=""
CONTEXT=""
OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
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

rb_ns_args=()
if [[ -n "$NAMESPACE" ]]; then
  rb_ns_args=(-n "$NAMESPACE")
else
  rb_ns_args=(--all-namespaces)
fi

rolebindings_json="$(${KUBECTL[@]} get rolebinding "${rb_ns_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"
clusterrolebindings_json="$(${KUBECTL[@]} get clusterrolebinding -o json 2>/dev/null || echo '{"items":[]}')"

findings_json="$(jq -c --argjson crbs "$clusterrolebindings_json" '
  def is_priv($role): ($role == "cluster-admin" or $role == "admin" or $role == "edit");

  (
    [
      .items[]?
      | select((.roleRef.kind // "") == "ClusterRole")
      | (.roleRef.name // "") as $role
      | select(is_priv($role))
      | {
          binding_kind: "RoleBinding",
          binding_name: .metadata.name,
          namespace: (.metadata.namespace // ""),
          role_kind: .roleRef.kind,
          role_name: $role,
          subjects: (.subjects // [])
        }
    ]
  )
  +
  (
    [
      $crbs.items[]?
      | select((.roleRef.kind // "") == "ClusterRole")
      | (.roleRef.name // "") as $role
      | select(is_priv($role))
      | {
          binding_kind: "ClusterRoleBinding",
          binding_name: .metadata.name,
          namespace: null,
          role_kind: .roleRef.kind,
          role_name: $role,
          subjects: (.subjects // [])
        }
    ]
  )
' <<< "$rolebindings_json")"

finding_count="$(jq 'length' <<< "$findings_json")"
rb_count="$(jq '.items | length' <<< "$rolebindings_json")"
crb_count="$(jq '.items | length' <<< "$clusterrolebindings_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --argjson rolebinding_count "$rb_count" \
    --argjson clusterrolebinding_count "$crb_count" \
    --argjson findings "$findings_json" \
    '{scope:$scope, context:$context, rolebinding_count:$rolebinding_count, clusterrolebinding_count:$clusterrolebinding_count, privileged_bindings:$findings}'
else
  echo "K8s RBAC Privileged Binding Auditor"
  echo "Scope (RoleBindings): ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "RoleBindings checked: $rb_count"
  echo "ClusterRoleBindings checked: $crb_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "No privileged bindings found for ClusterRoles {cluster-admin,admin,edit}."
  else
    echo "Privileged bindings found: $finding_count"
    jq -r '.[] | "- \(.binding_kind) \((.namespace // "cluster"))/\(.binding_name) role=\(.role_name) subjects=\(.subjects | length)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
