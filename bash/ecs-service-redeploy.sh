#!/usr/bin/env bash
set -euo pipefail

# Force a new deployment for an ECS service (works for EC2 or Fargate)
# Usage: ecs-service-redeploy.sh -c CLUSTER -s SERVICE [--dry-run]

usage(){
  cat <<EOF
Usage: $0 -c CLUSTER -s SERVICE [--dry-run]

Options:
  -c CLUSTER   ECS cluster name
  -s SERVICE   ECS service name
  --dry-run    Show the update command without performing it (default)
  --no-dry-run Perform the update
  -h           Help
EOF
}

CLUSTER=""
SERVICE=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CLUSTER="$2"; shift 2;;
    -s) SERVICE="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown $1"; usage; exit 2;;
  esac
done

if [[ -z "$CLUSTER" || -z "$SERVICE" ]]; then
  usage; exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI required"; exit 3
fi

echo "Forcing new deployment of service $SERVICE in cluster $CLUSTER"

# Get current task definition
td=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].taskDefinition' --output text)
if [[ -z "$td" || "$td" == "None" ]]; then
  echo "Could not determine task definition for $SERVICE"; exit 4
fi

echo "Current task definition: $td"

# Update service with forceNewDeployment
if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: aws ecs update-service --cluster $CLUSTER --service $SERVICE --force-new-deployment"
else
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --force-new-deployment
  echo "Triggered new deployment for $SERVICE"
fi

echo "Done."
