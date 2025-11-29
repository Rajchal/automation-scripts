#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 --action start|stop [--instances i-abc,i-def] [--tag Key=Value] [--region REGION] [--dry-run]

Options:
  --action       start or stop instances
  --instances    comma-separated instance IDs
  --tag          filter by tag (e.g. "Environment=prod")
  --region       AWS region (overrides AWS_REGION)
  --dry-run      perform aws cli dry-run (no changes)

Example:
  $0 --action stop --tag Environment=staging --region us-east-1
EOF
}

if [[ ${#@} -eq 0 ]]; then
  usage
  exit 1
fi

ACTION=""
INSTANCES=""
TAG=""
REGION=""
DRY_RUN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action)
      ACTION="$2"; shift 2;;
    --instances)
      INSTANCES="$2"; shift 2;;
    --tag)
      TAG="$2"; shift 2;;
    --region)
      REGION="$2"; shift 2;;
    --dry-run)
      DRY_RUN="--dry-run"; shift 1;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ "$ACTION" != "start" && "$ACTION" != "stop" ]]; then
  echo "--action must be 'start' or 'stop'" >&2; exit 2
fi

AWS_CLI=(aws)
if [[ -n "$REGION" ]]; then AWS_CLI+=(--region "$REGION"); fi

declare -a TARGET_IDS
if [[ -n "$INSTANCES" ]]; then
  IFS=',' read -r -a TARGET_IDS <<< "$INSTANCES"
fi

if [[ -z "${TARGET_IDS[*]}" && -n "$TAG" ]]; then
  KEY=${TAG%%=*}
  VALUE=${TAG#*=}
  mapfile -t TARGET_IDS < <(${AWS_CLI[*]} ec2 describe-instances --filters "Name=tag:${KEY},Values=${VALUE}" --query 'Reservations[].Instances[].InstanceId' --output text)
fi

if [[ ${#TARGET_IDS[@]} -eq 0 ]]; then
  echo "No matching instances found."; exit 0
fi

echo "Action: $ACTION"
echo "Instances: ${TARGET_IDS[*]}"
if [[ -n "$DRY_RUN" ]]; then echo "Dry run enabled"; fi

if [[ "$ACTION" == "start" ]]; then
  echo "Starting instances..."
  ${AWS_CLI[*]} ec2 start-instances --instance-ids ${TARGET_IDS[*]} $DRY_RUN
else
  echo "Stopping instances..."
  ${AWS_CLI[*]} ec2 stop-instances --instance-ids ${TARGET_IDS[*]} $DRY_RUN
fi

echo "Done."
