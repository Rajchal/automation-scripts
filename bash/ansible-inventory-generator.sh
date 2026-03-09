#!/usr/bin/env bash
set -euo pipefail

# ansible-inventory-generator.sh
# Generate an Ansible inventory from running EC2 instances.

usage() {
  cat <<EOF
Usage: $0 [--region REGION] [--group NAME] [--output FILE] [--private-ip]

Options:
  --region REGION   AWS region (default: us-east-1)
  --group NAME      Inventory group name (default: aws-hosts)
  --output FILE     Output inventory file (default: inventory.ini)
  --private-ip      Use private IP instead of public IP
  -h, --help        Show this help

Examples:
  bash/ansible-inventory-generator.sh
  bash/ansible-inventory-generator.sh --region ap-south-1 --output aws.ini
  bash/ansible-inventory-generator.sh --private-ip --group app-nodes
EOF
}

REGION="us-east-1"
GROUP="aws-hosts"
OUT_FILE="inventory.ini"
USE_PRIVATE_IP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="${2:-}"; shift 2 ;;
    --group) GROUP="${2:-}"; shift 2 ;;
    --output) OUT_FILE="${2:-}"; shift 2 ;;
    --private-ip) USE_PRIVATE_IP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required" >&2
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 3
fi

instances_json="$(aws ec2 describe-instances --region "$REGION" --output json 2>/dev/null || echo '{"Reservations":[]}')"

if [[ "$USE_PRIVATE_IP" == true ]]; then
  host_filter='.Reservations[]?.Instances[]? | select(.State.Name=="running") | .PrivateIpAddress // empty'
else
  host_filter='.Reservations[]?.Instances[]? | select(.State.Name=="running") | .PublicIpAddress // empty'
fi

mapfile -t hosts < <(jq -r "$host_filter" <<< "$instances_json" | awk 'NF' | sort -u)

{
  echo "[$GROUP]"
  for h in "${hosts[@]:-}"; do
    echo "$h"
  done
} > "$OUT_FILE"

echo "Inventory generated: $OUT_FILE"
echo "Hosts written: ${#hosts[@]}"
