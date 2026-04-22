#!/usr/bin/env bash
set -euo pipefail

# k8s-ingress-host-auditor.sh
# Detect Ingress resources that are missing rule hosts or any rules.

usage() {
  cat <<EOF
Usage: $0 [--output text|json] [--no-fail]

Options:
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even when findings are present
  -h, --help          Show this help

Notes:
  - Reports Ingress resources that do not define any rules or include rules with missing host values.
  - Useful for finding Ingress objects that may not route traffic as expected.

Examples:
  bash/k8s-ingress-host-auditor.sh
  bash/k8s-ingress-host-auditor.sh --output json
  bash/k8s-ingress-host-auditor.sh --output json --no-fail
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

ingresses_json="$(kubectl get ingress --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')"
findings="$(jq -c '
  .items[]?
  | {namespace:.metadata.namespace, name:.metadata.name, ruleCount:(.spec.rules // [] | length), hostNames:(.spec.rules // [] | map(.host // "") | unique)}
  | select(.ruleCount == 0 or (.hostNames | index("") != null))
' <<< "$ingresses_json")"

result="$(jq -n --argjson findings "[$findings]" '{ingresses_missing_hosts:$findings}')"
count="$(jq '.ingresses_missing_hosts | length' <<< "$result")"

if [[ "$OUTPUT" == "json" ]]; then
  echo "$result" | jq '.'
else
  if [[ "$count" -eq 0 ]]; then
    echo "No Ingress resources missing host rules were detected."
  else
    echo "Ingress resources missing host rules (count=$count):"
    jq -r '.ingresses_missing_hosts[] | "- \(.namespace)/\(.name) rules=\(.ruleCount) hosts=\(.hostNames | join(","))"' <<< "$result"
  fi
fi

if [[ "$NO_FAIL" == false && "$count" -gt 0 ]]; then
  exit 1
fi

exit 0
