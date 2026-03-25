#!/usr/bin/env bash
set -euo pipefail

# k8s-networkpolicy-default-deny-auditor.sh
# Detects namespaces with active workloads but no default deny NetworkPolicy.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Checks namespaces with pods that do not have at least one NetworkPolicy matching all pods in that namespace.
  - Find namespaces with potential open ingress/egress where default deny is missing.

Examples:
  bash/k8s-networkpolicy-default-deny-auditor.sh
  bash/k8s-networkpolicy-default-deny-auditor.sh --output json
  bash/k8s-networkpolicy-default-deny-auditor.sh --output json --no-fail
EOF
}

OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="${2:-}"; shift 2
      ;;
    --no-fail)
      NO_FAIL=true; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage; exit 2
      ;;
  esac
done

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "json" ]]; then
  echo "--output must be text or json" >&2
  exit 2
fi

for cmd in kubectl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required" >&2
    exit 3
  fi
done

namespaces="$(kubectl get ns -o json | jq -r '.items[].metadata.name')"

namespaces_with_pods="$(kubectl get pods --all-namespaces -o json | jq -r '.items[].metadata.namespace' | sort -u)"

missing_default_deny=()

for ns in $namespaces_with_pods; do
  np_count="$(kubectl get networkpolicy -n "$ns" -o json 2>/dev/null | jq '.items | length')"
  if [[ "$np_count" -eq 0 ]]; then
    missing_default_deny+=("$ns")
    continue
  fi

  has_default_deny="$(kubectl get networkpolicy -n "$ns" -o json 2>/dev/null | jq '[.items[] | select((.spec.podSelector == {} or .spec.podSelector == null) and (has(.spec.ingress|[]) | not or .spec.ingress==[]? | not) and (has(.spec.egress|[]) | not or .spec.egress==[]? | not))] | length')"

  if [[ "$has_default_deny" -eq 0 ]]; then
    missing_default_deny+=("$ns")
  fi
done

results_json="$(jq -n --argjson nps "$(printf '%s
' "${missing_default_deny[@]}" | jq -R . | jq -s .)" '{namespaces_missing_default_deny:$nps}')"

count="$(jq '.namespaces_missing_default_deny | length' <<< "$results_json")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$results_json" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No namespaces with pods are missing default deny NetworkPolicy."
  else
    echo "Namespaces with workloads but missing default deny network policy (count=$count):"
    jq -r '.namespaces_missing_default_deny[]' <<< "$results_json"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
