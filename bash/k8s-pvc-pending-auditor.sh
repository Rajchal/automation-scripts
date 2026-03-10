#!/usr/bin/env bash
set -euo pipefail

# k8s-pvc-pending-auditor.sh
# Find PersistentVolumeClaims stuck in Pending phase and surface likely provisioning hints.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--output text|json] [--no-fail]

Options:
  --namespace NS      Audit only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when pending PVCs are found
  -h, --help          Show this help

Examples:
  bash/k8s-pvc-pending-auditor.sh
  bash/k8s-pvc-pending-auditor.sh --namespace production
  bash/k8s-pvc-pending-auditor.sh --output json --no-fail
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

pending_json="$(jq -c '
  [
    .items[]?
    | select((.status.phase // "") == "Pending")
    | {
        namespace: .metadata.namespace,
        name: .metadata.name,
        storage_class: (.spec.storageClassName // "none"),
        requested_storage: (.spec.resources.requests.storage // "unknown"),
        volume_name: (.spec.volumeName // ""),
        volume_mode: (.spec.volumeMode // "Filesystem"),
        access_modes: (.spec.accessModes // []),
        age_seconds: ((now - ((.metadata.creationTimestamp // now) | fromdateiso8601)) | floor)
      }
  ]
' <<< "$pvcs_json")"

pending_count="$(jq 'length' <<< "$pending_json")"
pvc_count="$(jq '.items | length' <<< "$pvcs_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --argjson pvc_count "$pvc_count" \
    --argjson pending "$pending_json" \
    '{scope:$scope, context:$context, pvc_count:$pvc_count, pending_pvcs:$pending}'
else
  echo "K8s PVC Pending Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "PVCs scanned: $pvc_count"
  echo ""

  if [[ "$pending_count" -eq 0 ]]; then
    echo "No pending PVCs found."
  else
    echo "Pending PVCs: $pending_count"
    jq -r '.[] | "- \(.namespace)/\(.name) storageClass=\(.storage_class) requested=\(.requested_storage) accessModes=\(.access_modes | join(",")) ageSeconds=\(.age_seconds)"' <<< "$pending_json"
    echo ""
    echo "Hints: check StorageClass existence/provisioner, PV availability, access mode compatibility, and CSI provisioner health."
  fi
fi

if [[ "$pending_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
