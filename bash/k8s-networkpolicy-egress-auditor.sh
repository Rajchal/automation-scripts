#!/usr/bin/env bash
set -euo pipefail

# k8s-networkpolicy-egress-auditor.sh
# Detect NetworkPolicies that do not define egress policy rules.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Reports NetworkPolicies with ingress rules but missing egress rules.
  - Useful to identify policies that do not constrain egress traffic.

Examples:
  bash/k8s-networkpolicy-egress-auditor.sh
  bash/k8s-networkpolicy-egress-auditor.sh --output json
  bash/k8s-networkpolicy-egress-auditor.sh --output json --no-fail
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

nps_json="$(kubectl get networkpolicy --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
findings="$(jq -c '
  .items[]?
  | {namespace:.metadata.namespace, name:.metadata.name, ingress:(.spec.ingress // []), egress:(.spec.egress // []), policyTypes:(.spec.policyTypes // []), hasEgress:(.spec.egress != null)}
  | select((.ingress | length) > 0 and .hasEgress == false)
' <<< "$nps_json")"

result="$(jq -n --argjson findings "[$findings]" '{networkpolicies_missing_egress:$findings}')"
count="$(jq '.networkpolicies_missing_egress | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No NetworkPolicies missing egress rules were detected."
  else
    echo "NetworkPolicies missing egress rules (count=$count):"
    jq -r '.networkpolicies_missing_egress[] | "- \(.namespace)/\(.name)"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
