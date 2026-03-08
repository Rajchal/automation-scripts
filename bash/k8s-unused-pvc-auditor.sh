#!/usr/bin/env bash
set -euo pipefail

# k8s-unused-pvc-auditor.sh
# Find PersistentVolumeClaims that are not referenced by active pods.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--output text|json] [--no-fail]

Options:
  --namespace NS      Audit only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when unused PVCs are found
  -h, --help          Show this help

Notes:
  - Active pods are phases other than Succeeded/Failed.
  - A PVC is considered used if any active pod references it in volumes[].persistentVolumeClaim.claimName.

Examples:
  bash/k8s-unused-pvc-auditor.sh
  bash/k8s-unused-pvc-auditor.sh --namespace production
  bash/k8s-unused-pvc-auditor.sh --output json --no-fail
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

ns_args=()
if [[ -n "$NAMESPACE" ]]; then
  ns_args=(-n "$NAMESPACE")
else
  ns_args=(--all-namespaces)
fi

pvcs_json="$(${KUBECTL[@]} get pvc "${ns_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"
pods_json="$(${KUBECTL[@]} get pods "${ns_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

pvc_count="$(jq '.items | length' <<< "$pvcs_json")"
active_pod_count="$(jq '[.items[]? | select((.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed")] | length' <<< "$pods_json")"

# Build lookup map of namespace/name PVCs referenced by active pods.
declare -A used_pvc_map
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  used_pvc_map["$ref"]=1
done < <(jq -r '
  .items[]?
  | select((.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed")
  | .metadata.namespace as $ns
  | (.spec.volumes // [])[]?
  | .persistentVolumeClaim.claimName? // empty
  | select(length > 0)
  | "\($ns)/\(.)"
' <<< "$pods_json" | sort -u)

unused_json="[]"
while IFS= read -r pvc; do
  [[ -z "$pvc" ]] && continue
  ns="$(cut -d'/' -f1 <<< "$pvc")"
  name="$(cut -d'/' -f2- <<< "$pvc")"
  if [[ -z "${used_pvc_map[$pvc]:-}" ]]; then
    status="$(jq -r --arg ns "$ns" --arg name "$name" '.items[] | select(.metadata.namespace==$ns and .metadata.name==$name) | .status.phase // "Unknown"' <<< "$pvcs_json" | head -n1)"
    storage_class="$(jq -r --arg ns "$ns" --arg name "$name" '.items[] | select(.metadata.namespace==$ns and .metadata.name==$name) | .spec.storageClassName // "none"' <<< "$pvcs_json" | head -n1)"
    capacity="$(jq -r --arg ns "$ns" --arg name "$name" '.items[] | select(.metadata.namespace==$ns and .metadata.name==$name) | .status.capacity.storage // "unknown"' <<< "$pvcs_json" | head -n1)"
    unused_json="$(jq -c --arg ns "$ns" --arg name "$name" --arg status "$status" --arg sc "$storage_class" --arg cap "$capacity" '. + [{namespace:$ns, name:$name, status:$status, storage_class:$sc, capacity:$cap}]' <<< "$unused_json")"
  fi
done < <(jq -r '.items[]? | "\(.metadata.namespace)/\(.metadata.name)"' <<< "$pvcs_json")

unused_count="$(jq 'length' <<< "$unused_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --argjson pvc_count "$pvc_count" \
    --argjson active_pod_count "$active_pod_count" \
    --argjson unused "$unused_json" \
    '{scope:$scope, context:$context, pvc_count:$pvc_count, active_pod_count:$active_pod_count, unused_pvcs:$unused}'
else
  echo "K8s Unused PVC Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "PVCs scanned: $pvc_count"
  echo "Active pods scanned: $active_pod_count"
  echo ""

  if [[ "$unused_count" -eq 0 ]]; then
    echo "No unused PVCs found."
  else
    echo "Unused PVCs: $unused_count"
    jq -r '.[] | "- \(.namespace)/\(.name) status=\(.status) storageClass=\(.storage_class) capacity=\(.capacity)"' <<< "$unused_json"
  fi
fi

if [[ "$unused_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
