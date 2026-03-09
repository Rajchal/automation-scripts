#!/usr/bin/env bash
set -euo pipefail

# auto_dns_update.sh
# Minimal automation to update DNS records in AWS Route53.
# Dry-run by default; pass --apply to submit the change.

usage() {
  cat <<EOF
Usage: $0 [--provider route53] --zone-id ZONE --name FQDN. [--type A] --value VALUE [--ttl 300] [--apply]

Options:
  --provider P    DNS provider (supported: route53, default: route53)
  --zone-id Z     Route53 hosted zone id (required for route53)
  --name NAME     Record name (recommended with trailing dot)
  --type TYPE     DNS record type (default: A)
  --value VALUE   Record value (IP/target)
  --ttl N         TTL in seconds (default: 300)
  --apply         Apply change (default: dry-run)
  -h, --help      Show this help

Examples:
  bash/auto_dns_update.sh --zone-id Z1234 --name example.foo. --type A --value 1.2.3.4
  bash/auto_dns_update.sh --zone-id Z1234 --name example.foo. --type A --value 1.2.3.4 --apply
EOF
}

PROVIDER="route53"
ZONE_ID=""
NAME=""
TYPE="A"
VALUE=""
TTL=300
APPLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="${2:-}"; shift 2 ;;
    --zone-id) ZONE_ID="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    --type) TYPE="${2:-}"; shift 2 ;;
    --value) VALUE="${2:-}"; shift 2 ;;
    --ttl) TTL="${2:-}"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$PROVIDER" != "route53" ]]; then
  echo "Unsupported provider: $PROVIDER" >&2
  exit 1
fi
if [[ -z "$ZONE_ID" ]]; then
  echo "--zone-id is required for route53" >&2
  exit 2
fi
if [[ -z "$NAME" ]]; then
  echo "--name is required" >&2
  exit 2
fi
if [[ -z "$VALUE" ]]; then
  echo "--value is required" >&2
  exit 2
fi
if ! [[ "$TTL" =~ ^[0-9]+$ ]]; then
  echo "--ttl must be a non-negative integer" >&2
  exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required" >&2
  exit 3
fi

change_json="$(cat <<EOF
{
  "Comment": "auto_dns_update",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$NAME",
        "Type": "$TYPE",
        "TTL": $TTL,
        "ResourceRecords": [
          {"Value": "$VALUE"}
        ]
      }
    }
  ]
}
EOF
)"

echo "Planned change:"
if command -v jq >/dev/null 2>&1; then
  jq . <<< "$change_json"
else
  echo "$change_json"
fi

if [[ "$APPLY" == false ]]; then
  echo "Dry-run: no changes applied. Re-run with --apply to commit."
  exit 0
fi

change_id="$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch "$change_json" \
  --query 'ChangeInfo.Id' \
  --output text)"

echo "Change submitted: $change_id"
exit 0
