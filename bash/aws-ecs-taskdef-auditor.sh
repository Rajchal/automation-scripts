#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ecs-taskdef-auditor.log"
REPORT_FILE="/tmp/ecs-taskdef-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS ECS TaskDefinition Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_taskdef() {
  local td_arn="$1"
  td_json=$(aws ecs describe-task-definition --task-definition "$td_arn" --output json 2>/dev/null || echo '{}')
  td=$(echo "$td_json" | jq -c '.taskDefinition // empty')
  family=$(echo "$td" | jq -r '.family // ""')
  revision=$(echo "$td" | jq -r '.revision // ""')
  network_mode=$(echo "$td" | jq -r '.networkMode // ""')

  echo "TaskDefinition: ${family}:${revision} arn=${td_arn} networkMode=${network_mode}" >> "$REPORT_FILE"

  echo "$td" | jq -c '.containerDefinitions[]? // empty' | while read -r c; do
    cname=$(echo "$c" | jq -r '.name')
    image=$(echo "$c" | jq -r '.image // ""')
    privileged=$(echo "$c" | jq -r '.linuxParameters?.capabilities?.add // empty') || privileged=""
    readonly_root=$(echo "$c" | jq -r '.readonlyRootFilesystem // false')
    cpu=$(echo "$c" | jq -r '.cpu // empty')
    memory=$(echo "$c" | jq -r '.memory // empty')
    logconf=$(echo "$c" | jq -c '.logConfiguration // empty')

    echo "  Container: $cname image=$image cpu=$cpu memory=$memory readonlyRoot=$readonly_root" >> "$REPORT_FILE"

    # image tag checks
    if [[ "$image" =~ :latest$ ]] || [[ ! "$image" =~ : ]]; then
      echo "    IMAGE_TAG_LATEST_OR_UNTAGGED: $image" >> "$REPORT_FILE"
      send_slack_alert "ECS Alert: TaskDef ${family}:${revision} container $cname uses image tag 'latest' or untagged: $image"
    fi

    # privileged check (heuristic)
    if echo "$c" | jq -e '.privileged? // false' >/dev/null 2>&1 && [ "$(echo "$c" | jq -r '.privileged // false')" = "true" ]; then
      echo "    PRIVILEGED_CONTAINER: $cname" >> "$REPORT_FILE"
      send_slack_alert "ECS Alert: TaskDef ${family}:${revision} container $cname is privileged"
    fi

    # host port usage
    echo "$c" | jq -c '.portMappings[]? // empty' | while read -r pm; do
      hostp=$(echo "$pm" | jq -r '.hostPort // empty')
      contp=$(echo "$pm" | jq -r '.containerPort // empty')
      proto=$(echo "$pm" | jq -r '.protocol // empty')
      if [ -n "$hostp" ] && [ "$hostp" != "0" ]; then
        echo "    HOST_PORT_MAPPING: hostPort=$hostp containerPort=$contp proto=$proto" >> "$REPORT_FILE"
        send_slack_alert "ECS Alert: TaskDef ${family}:${revision} container $cname maps hostPort=$hostp (containerPort=$contp)"
      fi
    done

    # logging config
    if [ "$(echo "$logconf" | jq -r 'length')" = "0" ] || [ "$logconf" = "null" ]; then
      echo "    NO_LOG_CONFIGURATION" >> "$REPORT_FILE"
      send_slack_alert "ECS Notice: TaskDef ${family}:${revision} container $cname has no logConfiguration"
    fi

    # check environment vars for suspicious names
    echo "$c" | jq -c '.environment[]? // empty' | while read -r ev; do
      ename=$(echo "$ev" | jq -r '.name')
      if echo "$ename" | grep -Ei "PASSWORD|SECRET|TOKEN|KEY|AWS_SECRET" >/dev/null 2>&1; then
        echo "    POSSIBLE_PLAINTEXT_SECRET: env=$ename" >> "$REPORT_FILE"
        send_slack_alert "ECS Alert: TaskDef ${family}:${revision} container $cname has environment variable named $ename (possible secret)"
      fi
    done

    # resource limits
    if [ -z "$cpu" ] || [ "$cpu" = "null" ]; then
      echo "    MISSING_CPU" >> "$REPORT_FILE"
    fi
    if [ -z "$memory" ] || [ "$memory" = "null" ]; then
      echo "    MISSING_MEMORY" >> "$REPORT_FILE"
    fi
  done

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  # list active task definitions (limit recent)
  aws ecs list-task-definitions --status ACTIVE --output json 2>/dev/null | jq -r '.taskDefinitionArns[]? // empty' | while read -r td; do
    check_taskdef "$td"
  done

  log_message "ECS TaskDefinition audit written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ecs-taskdef-auditor.log"
REPORT_FILE="/tmp/ecs-taskdef-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message(){ echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert(){
  [ -n "$SLACK_WEBHOOK" ] || return 0
  payload=$(jq -n --arg t "$1" '{"text":$t}')
  curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
}

write_header(){
  echo "ECS Task Definition Auditor - $(date -u)" > "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_taskdef(){
  local td_arn="$1"
  td_json=$(aws ecs describe-task-definition --task-definition "$td_arn" --output json 2>/dev/null || echo '{}')
  family=$(echo "$td_json" | jq -r '.taskDefinition.family // ""')
  revision=$(echo "$td_json" | jq -r '.taskDefinition.revision // ""')
  networkMode=$(echo "$td_json" | jq -r '.taskDefinition.networkMode // ""')
  requiresCompat=$(echo "$td_json" | jq -r '.taskDefinition.requiresCompatibilities[]? // empty' | paste -sd"," -)

  echo "TaskDefinition: ${family}:${revision} arn=${td_arn}" >> "$REPORT_FILE"
  echo "  networkMode=${networkMode} requiresCompatibilities=${requiresCompat}" >> "$REPORT_FILE"

  if [ "$networkMode" = "host" ]; then
    echo "  WARNING: networkMode=host (containers share host network)" >> "$REPORT_FILE"
    send_slack_alert "ECS Alert: TaskDefinition ${family}:${revision} uses host networkMode"
  fi

  # iterate containers
  echo "$td_json" | jq -c '.taskDefinition.containerDefinitions[]? // empty' | while read -r c; do
    cname=$(echo "$c" | jq -r '.name')
    privileged=$(echo "$c" | jq -r '.linuxParameters.privileged // false' 2>/dev/null || echo false)
    host_pid=$(echo "$c" | jq -r '.linuxParameters.initProcessEnabled // false' 2>/dev/null || echo false)
    readonly_root=$(echo "$c" | jq -r '.readonlyRootFilesystem // false')

    echo "  Container: $cname privileged=$privileged readonlyRoot=$readonly_root" >> "$REPORT_FILE"

    if [ "$privileged" = "true" ]; then
      echo "    ISSUE: container runs privileged" >> "$REPORT_FILE"
      send_slack_alert "ECS Alert: Task ${family}:${revision} container $cname is privileged"
    fi

    # check port mappings host ports
    echo "$c" | jq -c '.portMappings[]? // empty' | while read -r pm; do
      host_port=$(echo "$pm" | jq -r '.hostPort // empty')
      container_port=$(echo "$pm" | jq -r '.containerPort // empty')
      protocol=$(echo "$pm" | jq -r '.protocol // "tcp"')
      if [ -n "$host_port" ] && [ "$host_port" != "0" ]; then
        echo "    HOST_PORT_MAPPING: hostPort=$host_port containerPort=$container_port proto=$protocol" >> "$REPORT_FILE"
        send_slack_alert "ECS Alert: Task ${family}:${revision} container $cname maps hostPort $host_port"
      fi
    done

    # check environment variables for plaintext secrets (heuristic)
    echo "$c" | jq -c '.environment[]? // empty' | while read -r env; do
      k=$(echo "$env" | jq -r '.name')
      v=$(echo "$env" | jq -r '.value // empty')
      if [ -n "$v" ] && echo "$k" | grep -Ei "(PASSWORD|SECRET|KEY|TOKEN)" >/dev/null 2>&1; then
        echo "    PLAINTEXT_ENV: $k looks sensitive and is set in taskdef (value hidden)" >> "$REPORT_FILE"
        send_slack_alert "ECS Alert: Task ${family}:${revision} container $cname contains plaintext env var $k"
      fi
    done
  done

  echo "" >> "$REPORT_FILE"
}

main(){
  write_header
  aws ecs list-task-definitions --output json 2>/dev/null | jq -r '.taskDefinitionArns[]? // empty' | while read -r td; do
    check_taskdef "$td"
  done
  log_message "ECS task-definition audit written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ecs-taskdef-auditor.log"
REPORT_FILE="/tmp/ecs-taskdef-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS ECS Task Definition Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_taskdef() {
  local arn="$1"
  info=$(aws ecs describe-task-definition --task-definition "$arn" --output json 2>/dev/null || echo '{}')
  td=$(echo "$info" | jq -c '.taskDefinition // {}')
  family=$(echo "$td" | jq -r '.family // ""')
  revision=$(echo "$td" | jq -r '.revision // ""')
  networkMode=$(echo "$td" | jq -r '.networkMode // ""')
  taskRoleArn=$(echo "$td" | jq -r '.taskRoleArn // empty')

  echo "TaskDefinition: ${family}:${revision} arn=${arn}" >> "$REPORT_FILE"
  echo "  networkMode=${networkMode} taskRoleArn=${taskRoleArn:-none}" >> "$REPORT_FILE"

  if [ "$networkMode" = "host" ]; then
    echo "  ISSUE: networkMode=host (exposes host network)" >> "$REPORT_FILE"
    send_slack_alert "ECS Alert: TaskDefinition ${family}:${revision} uses host networkMode"
  fi

  if [ -z "$taskRoleArn" ]; then
    echo "  WARNING: no taskRoleArn attached" >> "$REPORT_FILE"
  fi

  echo "$td" | jq -c '.containerDefinitions[]? // empty' | while read -r c; do
    cname=$(echo "$c" | jq -r '.name')
    image=$(echo "$c" | jq -r '.image // ""')
    privileged=$(echo "$c" | jq -r '.privileged // false')
    network_mode_container=$(echo "$c" | jq -r '.networkMode // empty' 2>/dev/null || echo "")

    echo "  Container: $cname image=$image privileged=$privileged" >> "$REPORT_FILE"

    # image tag checks
    if ! echo "$image" | grep -q ':'; then
      echo "    UNPINNED_IMAGE_TAG: image has no tag (likely 'latest')" >> "$REPORT_FILE"
      send_slack_alert "ECS Alert: Task ${family}:${revision} container $cname uses unpinned image $image"
    else
      tag=$(echo "$image" | awk -F: '{print $NF}')
      if [ "$tag" = "latest" ]; then
        echo "    UNPINNED_IMAGE_TAG: tag=latest" >> "$REPORT_FILE"
        send_slack_alert "ECS Alert: Task ${family}:${revision} container $cname uses :latest tag"
      fi
    fi

    if [ "$privileged" = "true" ]; then
      echo "    PRIVILEGED_CONTAINER: privileged=true" >> "$REPORT_FILE"
      send_slack_alert "ECS Alert: Task ${family}:${revision} container $cname runs privileged=true"
    fi

    # environment secrets heuristic
    echo "$c" | jq -c '.environment[]? // empty' | while read -r env; do
      key=$(echo "$env" | jq -r '.name')
      if echo "$key" | grep -Ei 'PASSWORD|SECRET|TOKEN|KEY|AWS_SECRET' >/dev/null 2>&1; then
        echo "    ENV_POTENTIAL_SECRET: $key" >> "$REPORT_FILE"
        send_slack_alert "ECS Alert: Task ${family}:${revision} container $cname has env var $key (possible secret)"
      fi
    done

    # mounts / host volumes
    echo "$c" | jq -c '.mountPoints[]? // empty' | while read -r mp; do
      src=$(echo "$mp" | jq -r '.sourceVolume // empty')
      if [ -n "$src" ]; then
        # check if the volume maps to host path
        volinfo=$(echo "$td" | jq -c --arg v "$src" '.volumes[]? | select(.name==$v)') || true
        hostpath=$(echo "$volinfo" | jq -r '.host.sourcePath // empty' || true)
        if [ -n "$hostpath" ]; then
          echo "    HOST_VOLUME_MOUNT: sourceVolume=$src hostPath=$hostpath" >> "$REPORT_FILE"
          send_slack_alert "ECS Alert: Task ${family}:${revision} container $cname mounts host path $hostpath"
        fi
      fi
    done

    # resource checks
    cpu=$(echo "$c" | jq -r '.cpu // 0')
    mem=$(echo "$c" | jq -r '.memory // .memoryReservation // 0')
    if [ "$cpu" -eq 0 ] || [ "$mem" -eq 0 ]; then
      echo "    RESOURCE_NOT_SET: cpu=$cpu memory=$mem" >> "$REPORT_FILE"
    fi
  done

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header
  # list active task definitions
  aws ecs list-task-definitions --status ACTIVE --output json 2>/dev/null | jq -r '.taskDefinitionArns[]? // empty' | while read -r arn; do
    check_taskdef "$arn"
  done

  log_message "ECS task-definition audit written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ecs-taskdef-auditor.log"
REPORT_FILE="/tmp/ecs-taskdef-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
OLD_REV_THRESHOLD="${ECS_TASKDEF_OLD_REVISIONS:-5}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS ECS Task Definition Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Old revision threshold: $OLD_REV_THRESHOLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_task_family() {
  local family="$1"
  echo "TaskFamily: $family" >> "$REPORT_FILE"

  # list revisions
  revs=$(aws ecs list-task-definitions --family-prefix "$family" --sort DESC --output json 2>/dev/null | jq -r '.taskDefinitionArns[]?')
  rev_count=0
  for r in $revs; do
    rev_count=$((rev_count+1))
  done
  echo "  Revisions: $rev_count" >> "$REPORT_FILE"
  if [ "$rev_count" -gt "$OLD_REV_THRESHOLD" ]; then
    echo "  MANY_REVISIONS: $rev_count > $OLD_REV_THRESHOLD" >> "$REPORT_FILE"
    send_slack_alert "ECS Alert: Task family $family has $rev_count revisions (> $OLD_REV_THRESHOLD)"
  fi

  # check latest revision details
  latest=$(echo "$revs" | head -n1)
  if [ -n "$latest" ]; then
    td=$(aws ecs describe-task-definition --task-definition "$latest" --output json 2>/dev/null || echo '{}')
    echo "  Latest: $latest" >> "$REPORT_FILE"

    # check container images for :latest usage
    echo "$td" | jq -c '.taskDefinition.containerDefinitions[]? // empty' | while read -r c; do
      name=$(echo "$c" | jq -r '.name')
      image=$(echo "$c" | jq -r '.image')
      echo "    Container: $name image=$image" >> "$REPORT_FILE"
      if echo "$image" | grep -E ':latest$' >/dev/null 2>&1; then
        echo "      USES_LATEST_TAG" >> "$REPORT_FILE"
        send_slack_alert "ECS Alert: Task family $family container $name uses :latest tag (image=$image)"
      fi

      # check environment variables for potential plaintext secrets (heuristic)
      echo "$c" | jq -c '.environment[]? // empty' | while read -r env; do
        key=$(echo "$env" | jq -r '.name')
        val=$(echo "$env" | jq -r '.value // empty')
        if echo "$key" | grep -Ei 'password|secret|token|key' >/dev/null 2>&1; then
          echo "      ENV_POTENTIAL_SECRET: $key" >> "$REPORT_FILE"
          send_slack_alert "ECS Alert: Task family $family container $name has env var $key (potential secret)"
        fi
      done
    done
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  aws ecs list-task-definition-families --output json 2>/dev/null | jq -r '.families[]? // empty' | while read -r fam; do
    check_task_family "$fam"
  done

  log_message "ECS task-definition audit written to $REPORT_FILE"
}

main "$@"
