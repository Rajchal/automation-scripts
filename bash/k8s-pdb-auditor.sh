#!/usr/bin/env bash
set -euo pipefail

# k8s-pdb-auditor.sh
# Report workloads (Deployments/StatefulSets) that do not have a matching PodDisruptionBudget.

usage() {
  cat <<EOF
Usage: $0 [--namespace NS] [--context CONTEXT] [--selector KEY=VALUE] [--output text|json]

Options:
  --namespace NS      Check only one namespace (default: all namespaces)
  --context CONTEXT   Kubernetes context to use
  --selector S        Label selector to filter workloads (default: none)
  --output FORMAT     Output format: text (default) or json
  -h, --help          Show this help message

Examples:
  # Audit all namespaces
  bash/k8s-pdb-auditor.sh

  # Audit only production namespace
  bash/k8s-pdb-auditor.sh --namespace production

  # JSON output for CI/reporting
  bash/k8s-pdb-auditor.sh --output json
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

workloads_json="$(${KUBECTL[@]} get deploy,statefulset "${ns_args[@]}" "${selector_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"
pdbs_json="$(${KUBECTL[@]} get pdb "${ns_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"

# Build namespace/name list of workloads that are selected by at least one PDB.
covered_pairs="$(jq -r '
  [
    .items[]?
    | .metadata.namespace as $ns
    | (.spec.selector.matchLabels // {}) as $match
    | select(($match | length) > 0)
    | $ns as $pdb_ns
    | $match
  ]
' <<< "$pdbs_json" >/dev/null 2>&1; 

jq -r --argjson wl "$workloads_json" '
  def match_labels($selector; $labels):
    ($selector | to_entries | all(. as $e | ($labels[$e.key] == $e.value)));

  [
    .items[]?
    | .metadata.namespace as $pdb_ns
    | (.spec.selector.matchLabels // {}) as $selector
    | select(($selector | length) > 0)
    | ($wl.items[]?
      | select(.metadata.namespace == $pdb_ns)
      | .metadata.labels as $labels
      | select(($labels // {} | length) > 0)
      | select(match_labels($selector; $labels))
      | "\(.metadata.namespace)/\(.kind)/\(.metadata.name)")
  ]
  | unique[]
' <<< "$pdbs_json")"

# Convert covered list into lookup map for fast checks.
declare -A covered_map
while IFS= read -r pair; do
  [[ -z "$pair" ]] && continue
  covered_map["$pair"]=1
done <<< "$covered_pairs"

missing_json="[]"
while IFS= read -r wl; do
  [[ -z "$wl" ]] && continue
  key="$wl"
  if [[ -z "${covered_map[$key]:-}" ]]; then
    ns="$(cut -d'/' -f1 <<< "$wl")"
    kind="$(cut -d'/' -f2 <<< "$wl")"
    name="$(cut -d'/' -f3- <<< "$wl")"
    missing_json="$(jq -c --arg ns "$ns" --arg kind "$kind" --arg name "$name" '. + [{namespace:$ns, kind:$kind, name:$name}]' <<< "$missing_json")"
  fi
done < <(jq -r '.items[]? | "\(.metadata.namespace)/\(.kind)/\(.metadata.name)"' <<< "$workloads_json")

missing_count="$(jq 'length' <<< "$missing_json")"
workload_count="$(jq '.items | length' <<< "$workloads_json")"
pdb_count="$(jq '.items | length' <<< "$pdbs_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg scope "${NAMESPACE:-all}" \
    --arg context "${CONTEXT:-current}" \
    --arg selector "${SELECTOR:-none}" \
    --argjson workloads "$workload_count" \
    --argjson pdbs "$pdb_count" \
    --argjson missing "$missing_json" \
    '{scope:$scope, context:$context, selector:$selector, workload_count:$workloads, pdb_count:$pdbs, missing_pdb_for_workloads:$missing}'
else
  echo "K8s PDB Auditor"
  echo "Scope: ${NAMESPACE:-all namespaces}"
  echo "Context: ${CONTEXT:-current}"
  echo "Selector: ${SELECTOR:-none}"
  echo "Workloads checked: $workload_count"
  echo "PDBs found: $pdb_count"
  echo ""

  if [[ "$missing_count" -eq 0 ]]; then
    echo "All checked workloads appear to be covered by at least one PDB."
  else
    echo "Workloads missing matching PDB: $missing_count"
    jq -r '.[] | "- \(.namespace)/\(.kind)/\(.name)"' <<< "$missing_json"
  fi
fi

if [[ "$missing_count" -gt 0 ]]; then
  exit 1
fi

exit 0
