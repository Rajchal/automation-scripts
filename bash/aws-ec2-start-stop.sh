#!/usr/bin/env bash
set -euo pipefail

# Manage EC2 instances by action and filter (safe, dry-run by default).
# Usage: aws-ec2-start-stop.sh -a start|stop|reboot (-t Key=Value | -i i-123,i-456) [--region us-east-1] [--dry-run]

usage(){
  cat <<EOF
Usage: $0 -a ACTION (-t Key=Value | -i id[,id...]) [--region REGION] [--dry-run]

Actions:
  start     Start matching instances
  stop      Stop matching instances
  reboot    Reboot matching instances

Options:
  -a ACTION       One of: start, stop, reboot
  -t TAG          Tag filter, format: Key=Value (e.g. Environment=prod)
  -i IDS          Comma-separated instance IDs (e.g. i-012345,i-0ab12)
  --region REGION AWS region (optional; uses AWS_DEFAULT_REGION if unset)
  --dry-run       Only print the aws commands (default)
  --no-dry-run    Execute commands
  -h              Show this help
EOF
}

ACTION=""
TAG_FILTER=""
IDS=""
REGION=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a) ACTION="$2"; shift 2;;
    -t) TAG_FILTER="$2"; shift 2;;
    -i) IDS="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1"; usage; exit 2;;
  esac
done

if [[ -z "$ACTION" ]]; then
  echo "Action is required."; usage; exit 2
fi

if [[ "$ACTION" != "start" && "$ACTION" != "stop" && "$ACTION" != "reboot" ]]; then
  echo "Invalid action: $ACTION"; usage; exit 2
fi

if [[ -z "$TAG_FILTER" && -z "$IDS" ]]; then
  echo "Either -t TAG or -i IDS is required to select instances."; usage; exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not found; please install and configure AWS CLI."; exit 3
fi

AWS_CMD_BASE=(aws ec2)
if [[ -n "$REGION" ]]; then
  AWS_CMD_BASE+=(--region "$REGION")
fi

# Build instance list
if [[ -n "$IDS" ]]; then
  IFS=',' read -r -a instance_array <<< "$IDS"
else
  # Use tag filter
  if [[ "$TAG_FILTER" != *=* ]]; then
    echo "Tag filter must be in Key=Value format."; exit 2
  fi
  key=${TAG_FILTER%%=*}
  val=${TAG_FILTER#*=}
  mapfile -t instance_array < <(${AWS_CMD_BASE[@]} describe-instances --filters "Name=tag:${key},Values=${val}" --query 'Reservations[].Instances[].InstanceId' --output text)
fi

if [[ ${#instance_array[@]} -eq 0 ]]; then
  echo "No instances found matching the criteria."; exit 0
fi

echo "Action: $ACTION";
echo "Instances: ${instance_array[*]}";
echo "Dry run: $DRY_RUN";

case "$ACTION" in
  start)
    verb="start-instances";;
  stop)
    verb="stop-instances";;
  reboot)
    verb="reboot-instances";;
esac

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: ${AWS_CMD_BASE[*]} $verb --instance-ids ${instance_array[*]}"
else
  ${AWS_CMD_BASE[@]} $verb --instance-ids ${instance_array[*]}
  echo "Requested $ACTION for instances: ${instance_array[*]}"
fi

echo "Done."
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
