#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ecs-service-monitor.log"
REPORT_FILE="/tmp/ecs-service-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
UNHEALTHY_TASK_THRESHOLD="${ECS_UNHEALTHY_TASK_THRESHOLD:-1}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -z "$SLACK_WEBHOOK" ]; then
    return
  fi
  payload=$(jq -n --arg t "$1" '{"text":$t}')
  curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
}

write_header() {
  echo "ECS Service Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Unhealthy task alert threshold: $UNHEALTHY_TASK_THRESHOLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

count_unhealthy_tasks() {
  # args: cluster arn, service arn
  cluster_arn="$1"
  service_arn="$2"

  task_arns=$(aws ecs list-tasks --cluster "$cluster_arn" --service-name "$service_arn" --desired-status RUNNING --region "$REGION" --output json 2>/dev/null | jq -r '.taskArns[]?')
  if [ -z "$task_arns" ]; then
    echo 0
    return
  fi

  # describe tasks in batches
  unhealthy=0
  for t in $task_arns; do
    dt=$(aws ecs describe-tasks --cluster "$cluster_arn" --tasks "$t" --region "$REGION" --output json 2>/dev/null || echo '{}')
    # Count container healthStatus == UNHEALTHY (if present)
    cnt=$(echo "$dt" | jq -r '.tasks[]?.containers[]?.healthStatus? | select(.=="UNHEALTHY")' 2>/dev/null | wc -l || true)
    if [ "$cnt" -gt 0 ]; then
      unhealthy=$((unhealthy+cnt))
    fi
  done
  echo "$unhealthy"
}

main() {
  write_header

  clusters_json=$(aws ecs list-clusters --region "$REGION" --output json 2>/dev/null || echo '{"clusterArns":[]}')
  clusters=$(echo "$clusters_json" | jq -r '.clusterArns[]?')

  if [ -z "$clusters" ]; then
    echo "No ECS clusters found." >> "$REPORT_FILE"
    log_message "No ECS clusters in region $REGION"
    exit 0
  fi

  total_services=0
  alert_count=0

  for c in $clusters; do
    echo "Cluster: $c" >> "$REPORT_FILE"
    services_json=$(aws ecs list-services --cluster "$c" --region "$REGION" --output json 2>/dev/null || echo '{"serviceArns":[]}')
    services=$(echo "$services_json" | jq -r '.serviceArns[]?')
    if [ -z "$services" ]; then
      echo "  No services in cluster." >> "$REPORT_FILE"
      echo "" >> "$REPORT_FILE"
      continue
    fi

    for s in $services; do
      total_services=$((total_services+1))
      desc=$(aws ecs describe-services --cluster "$c" --services "$s" --region "$REGION" --output json 2>/dev/null || echo '{"services":[]}')
      svc=$(echo "$desc" | jq -r '.services[0] // {}')
      name=$(echo "$svc" | jq -r '.serviceName // "<unknown>"')
      desired=$(echo "$svc" | jq -r '.desiredCount // 0')
      running=$(echo "$svc" | jq -r '.runningCount // 0')
      pending=$(echo "$svc" | jq -r '.pendingCount // 0')
      deployments=$(echo "$svc" | jq -r '.deployments | length')

      echo "  Service: $name" >> "$REPORT_FILE"
      echo "    Desired: $desired" >> "$REPORT_FILE"
      echo "    Running: $running" >> "$REPORT_FILE"
      echo "    Pending: $pending" >> "$REPORT_FILE"
      echo "    Deployments: $deployments" >> "$REPORT_FILE"

      if [ "$running" -lt "$desired" ]; then
        echo "    ALERT: running ($running) < desired ($desired)" >> "$REPORT_FILE"
        send_slack_alert "ECS Alert: Service $name in cluster $c has running=$running desired=$desired"
        alert_count=$((alert_count+1))
      fi

      # Count unhealthy tasks via container health status when available
      unhealthy_tasks=$(count_unhealthy_tasks "$c" "$s")
      echo "    Unhealthy tasks (container health): $unhealthy_tasks" >> "$REPORT_FILE"
      if [ "$unhealthy_tasks" -ge "$UNHEALTHY_TASK_THRESHOLD" ]; then
        send_slack_alert "ECS Alert: Service $name in cluster $c has $unhealthy_tasks unhealthy container(s)"
        alert_count=$((alert_count+1))
      fi

      echo "" >> "$REPORT_FILE"
    done
  done

  echo "Summary: total_services=$total_services, alerts=$alert_count" >> "$REPORT_FILE"
  log_message "ECS report written to $REPORT_FILE (total_services=$total_services, alerts=$alert_count)"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ecs-service-monitor.log"
REPORT_FILE="/tmp/ecs-service-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MAX_SERVICES_PER_CLUSTER="${ECS_MAX_SERVICES:-200}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "ECS Service Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_service() {
  local cluster_arn="$1"
  local service_arn="$2"

  svc_json=$(aws ecs describe-services --cluster "$cluster_arn" --services "$service_arn" --region "$REGION" --output json 2>/dev/null || echo '{"services":[]}')
  svc=$(echo "$svc_json" | jq -r '.services[0] // {}')
  name=$(echo "$svc" | jq -r '.serviceName // "<unknown>"')
  desired=$(echo "$svc" | jq -r '.desiredCount // 0')
  running=$(echo "$svc" | jq -r '.runningCount // 0')
  pending=$(echo "$svc" | jq -r '.pendingCount // 0')
  deployments=$(echo "$svc" | jq -c '.deployments // []')
  events=$(echo "$svc" | jq -c '.events // []')

  echo "Service: $name" >> "$REPORT_FILE"
  echo "  Desired: $desired" >> "$REPORT_FILE"
  echo "  Running: $running" >> "$REPORT_FILE"
  echo "  Pending: $pending" >> "$REPORT_FILE"

  # Check mismatch
  if [ "$running" -lt "$desired" ]; then
    send_slack_alert "ECS Alert: Service $name has running=$running less than desired=$desired in cluster $cluster_arn"
  fi

  if [ "$pending" -gt 0 ]; then
    send_slack_alert "ECS Alert: Service $name has $pending pending tasks in cluster $cluster_arn"
  fi

  # Check recent events for unhealthy/failures
  echo "$events" | jq -r '.[]? | .message' | while read -r msg; do
    if echo "$msg" | grep -Ei "fail|error|unhealthy|stopped|terminated|insufficient" >/dev/null 2>&1; then
      send_slack_alert "ECS Event: Service $name in cluster $cluster_arn: $msg"
    fi
  done

  # Check deployments for long-running primary deployment not completed
  echo "$deployments" | jq -c '.[]?' | while read -r d; do
    status=$(echo "$d" | jq -r '.status // ""')
    desiredCount=$(echo "$d" | jq -r '.desiredCount // 0')
    runningCount=$(echo "$d" | jq -r '.runningCount // 0')
    if [ "$runningCount" -lt "$desiredCount" ]; then
      send_slack_alert "ECS Deployment: Service $name in cluster $cluster_arn deployment status=$status running=$runningCount desired=$desiredCount"
    fi
  done

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  clusters_json=$(aws ecs list-clusters --region "$REGION" --output json 2>/dev/null || echo '{"clusterArns":[]}')
  clusters=$(echo "$clusters_json" | jq -r '.clusterArns[]?')

  if [ -z "$clusters" ]; then
    echo "No ECS clusters found." >> "$REPORT_FILE"
    log_message "No ECS clusters in region $REGION"
    exit 0
  fi

  echo "Found clusters:" >> "$REPORT_FILE"
  for c in $clusters; do
    echo "  $c" >> "$REPORT_FILE"
  done
  echo "" >> "$REPORT_FILE"

  for cluster in $clusters; do
    services_json=$(aws ecs list-services --cluster "$cluster" --max-results "$MAX_SERVICES_PER_CLUSTER" --region "$REGION" --output json 2>/dev/null || echo '{"serviceArns":[]}')
    services=$(echo "$services_json" | jq -r '.serviceArns[]?')
    if [ -z "$services" ]; then
      echo "Cluster $cluster: no services" >> "$REPORT_FILE"
      continue
    fi

    echo "Checking cluster: $cluster" >> "$REPORT_FILE"
    for s in $services; do
      check_service "$cluster" "$s"
    done
    echo "" >> "$REPORT_FILE"
  done

  log_message "ECS service report written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ecs-service-monitor.log"
REPORT_FILE="/tmp/ecs-service-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
SERVICE_FAIL_THRESHOLD="${ECS_SERVICE_FAIL_THRESHOLD:-3}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "ECS Service Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Service failure alert threshold: $SERVICE_FAIL_THRESHOLD events" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  clusters_json=$(aws ecs list-clusters --region "$REGION" --output json 2>/dev/null || echo '{"clusterArns":[]}')
  cluster_arns=$(echo "$clusters_json" | jq -r '.clusterArns[]?')

  if [ -z "$cluster_arns" ]; then
    echo "No ECS clusters found." >> "$REPORT_FILE"
    log_message "No ECS clusters in $REGION"
    exit 0
  fi

  total_services=0
  alerts=0

  for cluster in $cluster_arns; do
    cluster_name=$(basename "$cluster")
    echo "Cluster: $cluster_name ($cluster)" >> "$REPORT_FILE"

    svc_list=$(aws ecs list-services --cluster "$cluster" --region "$REGION" --output json 2>/dev/null || echo '{"serviceArns":[]}')
    services=$(echo "$svc_list" | jq -r '.serviceArns[]?')
    if [ -z "$services" ]; then
      echo "  No services in cluster." >> "$REPORT_FILE"
      echo "" >> "$REPORT_FILE"
      continue
    fi

    # describe in batches of up to 10
    service_batch=()
    for s in $services; do
      service_batch+=("$s")
      if [ "${#service_batch[@]}" -ge 10 ]; then
        describe_and_check "$cluster" "${service_batch[@]}" >> "$REPORT_FILE"
        service_batch=()
      fi
    done
    if [ "${#service_batch[@]}" -gt 0 ]; then
      describe_and_check "$cluster" "${service_batch[@]}" >> "$REPORT_FILE"
    fi
  done

  log_message "ECS report written to $REPORT_FILE"
}

describe_and_check() {
  local cluster="$1"
  shift
  local services=("$@")
  # Build JSON array argument for aws CLI
  svc_args=$(printf '%s ' "${services[@]}")
  desc=$(aws ecs describe-services --cluster "$cluster" --services $svc_args --region "$REGION" --output json 2>/dev/null || echo '{"services":[]}')

  echo "$desc" | jq -c '.services[]?' | while read -r svc; do
    total_services=$((total_services+1))
    svc_name=$(echo "$svc" | jq -r '.serviceName')
    desired=$(echo "$svc" | jq -r '.desiredCount // 0')
    running=$(echo "$svc" | jq -r '.runningCount // 0')
    pending=$(echo "$svc" | jq -r '.pendingCount // 0')
    deployments=$(echo "$svc" | jq -c '.deployments[]?')
    events_count=$(echo "$svc" | jq -r '.events | length')

    echo "  Service: $svc_name" >> "$REPORT_FILE"
    echo "    Desired: $desired, Running: $running, Pending: $pending" >> "$REPORT_FILE"

    if [ "$running" -lt "$desired" ]; then
      echo "    ALERT: running < desired for $svc_name" >> "$REPORT_FILE"
      send_slack_alert "ECS Alert: Service $svc_name in cluster $(basename "$cluster") has running=$running desired=$desired"
      alerts=$((alerts+1))
    fi

    if [ "$pending" -gt 0 ] && [ "$running" -eq 0 ]; then
      echo "    ALERT: pending tasks present but no running tasks for $svc_name" >> "$REPORT_FILE"
      send_slack_alert "ECS Alert: Service $svc_name has $pending pending tasks but 0 running tasks"
      alerts=$((alerts+1))
    fi

    # Check recent events for failures
    if [ "$events_count" -gt 0 ]; then
      # look for failure keywords
      bad_events=$(echo "$svc" | jq -r '.events[]?.message' | grep -Ei "fail|error|unhealthy|unable|stopped" || true)
      if [ -n "$bad_events" ]; then
        cnt=$(echo "$bad_events" | wc -l || true)
        echo "    Found $cnt suspicious event(s) for $svc_name:" >> "$REPORT_FILE"
        echo "$bad_events" | sed 's/^/      /' >> "$REPORT_FILE"
        send_slack_alert "ECS Alert: Service $svc_name has $cnt failure/health events. Check service events." 
        alerts=$((alerts+1))
      fi
    fi

    # Check deployments for many stopped tasks or older primary deployment stuck
    echo "" >> "$REPORT_FILE"
  done
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ecs-service-monitor.log"
REPORT_FILE="/tmp/ecs-service-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
SERVICE_FAILURE_THRESHOLD="${ECS_SERVICE_FAILURE_THRESHOLD:-3}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "ECS Service Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Service failure alert threshold: $SERVICE_FAILURE_THRESHOLD events" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_service() {
  local cluster_arn="$1"
  local service_arn="$2"

  svc_json=$(aws ecs describe-services --cluster "$cluster_arn" --services "$service_arn" --region "$REGION" --output json 2>/dev/null || echo '{}')
  svc=$(echo "$svc_json" | jq -r '.services[0] // {}')
  if [ "$svc" = "{}" ]; then
    echo "  Service: $service_arn - unable to describe" >> "$REPORT_FILE"
    return
  fi

  name=$(echo "$svc" | jq -r '.serviceName // "<unknown>"')
  desired=$(echo "$svc" | jq -r '.desiredCount // 0')
  running=$(echo "$svc" | jq -r '.runningCount // 0')
  pending=$(echo "$svc" | jq -r '.pendingCount // 0')
  deployments=$(echo "$svc" | jq -r '.deployments | length')
  # Check recent events for failures
  events_count=$(echo "$svc" | jq -r '.events | length')

  echo "Service: $name" >> "$REPORT_FILE"
  echo "  Desired: $desired, Running: $running, Pending: $pending, Deployments: $deployments" >> "$REPORT_FILE"

  # Summarize recent event messages and detect error keywords
  if [ "$events_count" -gt 0 ]; then
    echo "  Recent events:" >> "$REPORT_FILE"
    echo "$svc" | jq -r '.events[] | "    - [\(.createdAt)] \(.message)"' >> "$REPORT_FILE"
    err_count=$(echo "$svc" | jq -r '.events[] | select(.message|test("fail|error|unhealthy|unable|Stopped|ERROR"; "i")) | length' 2>/dev/null || echo 0)
  else
    err_count=0
  fi

  echo "" >> "$REPORT_FILE"

  if [ "$running" -lt "$desired" ]; then
    send_slack_alert "ECS Alert: Service $name in cluster $(basename $cluster_arn) has running=$running desired=$desired"
  fi

  if [ "$err_count" -ge "$SERVICE_FAILURE_THRESHOLD" ]; then
    send_slack_alert "ECS Alert: Service $name in cluster $(basename $cluster_arn) has $err_count recent error events"
  fi
}

main() {
  write_header

  clusters_json=$(aws ecs list-clusters --region "$REGION" --output json 2>/dev/null || echo '{"clusterArns":[]}')
  clusters=$(echo "$clusters_json" | jq -r '.clusterArns[]?')

  if [ -z "$clusters" ]; then
    echo "No ECS clusters found." >> "$REPORT_FILE"
    log_message "No ECS clusters in region $REGION"
    exit 0
  fi

  echo "Checking ECS clusters and services..." >> "$REPORT_FILE"
  for c in $clusters; do
    echo "Cluster: $(basename $c) ($c)" >> "$REPORT_FILE"
    svc_list_json=$(aws ecs list-services --cluster "$c" --region "$REGION" --output json 2>/dev/null || echo '{"serviceArns":[]}')
    services=$(echo "$svc_list_json" | jq -r '.serviceArns[]?')
    if [ -z "$services" ]; then
      echo "  No services in cluster." >> "$REPORT_FILE"
      echo "" >> "$REPORT_FILE"
      continue
    fi

    for s in $services; do
      check_service "$c" "$s"
    done
    echo "" >> "$REPORT_FILE"
  done

  log_message "ECS service report written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ecs-service-monitor.log"
REPORT_FILE="/tmp/ecs-service-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MAX_SERVICES="${ECS_MAX_SERVICES:-200}"
UNHEALTHY_THRESHOLD="${ECS_UNHEALTHY_THRESHOLD:-1}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "ECS Service Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Max services per cluster: $MAX_SERVICES" >> "$REPORT_FILE"
  echo "Unhealthy tasks threshold: $UNHEALTHY_THRESHOLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  clusters_json=$(aws ecs list-clusters --region "$REGION" --output json 2>/dev/null || echo '{"clusterArns":[]}')
  clusters=$(echo "$clusters_json" | jq -r '.clusterArns[]?')

  if [ -z "$clusters" ]; then
    echo "No ECS clusters found." >> "$REPORT_FILE"
    log_message "No ECS clusters in region $REGION"
    exit 0
  fi

  total_services=0
  alerts=0

  for c in $clusters; do
    c_name=$(basename "$c")
    echo "Cluster: $c_name ($c)" >> "$REPORT_FILE"

    services_json=$(aws ecs list-services --cluster "$c" --max-results "$MAX_SERVICES" --region "$REGION" --output json 2>/dev/null || echo '{"serviceArns":[]}')
    services=$(echo "$services_json" | jq -r '.serviceArns[]?')
    if [ -z "$services" ]; then
      echo "  No services in cluster." >> "$REPORT_FILE"
      echo "" >> "$REPORT_FILE"
      continue
    fi

    echo "  Services:" >> "$REPORT_FILE"
    for s in $services; do
      total_services=$((total_services+1))
      svc_name=$(basename "$s")
      desc=$(aws ecs describe-services --cluster "$c" --services "$svc_name" --region "$REGION" --output json 2>/dev/null || echo '{"services":[]}')
      desired=$(echo "$desc" | jq -r '.services[0].desiredCount // 0')
      running=$(echo "$desc" | jq -r '.services[0].runningCount // 0')
      pending=$(echo "$desc" | jq -r '.services[0].pendingCount // 0')
      deployments=$(echo "$desc" | jq -r '.services[0].deployments | length')
      unhealthy=$(echo "$desc" | jq -r '.services[0].events[]? | select(.message | test("(unhealthy|TASK\sFAILED|STOPPED)"; "i")) | .message' 2>/dev/null | wc -l || true)

      echo "    Service: $svc_name" >> "$REPORT_FILE"
      echo "      desired=$desired running=$running pending=$pending deployments=$deployments unhealthy_events=$unhealthy" >> "$REPORT_FILE"
      echo "" >> "$REPORT_FILE"

      if [ "$running" -lt "$desired" ] || [ "$unhealthy" -ge "$UNHEALTHY_THRESHOLD" ]; then
        send_slack_alert "ECS Alert: Service $svc_name in cluster $c_name desired=$desired running=$running unhealthy_events=$unhealthy"
        alerts=$((alerts+1))
      fi
    done

    echo "" >> "$REPORT_FILE"
  done

  echo "Summary: total_services=$total_services, alerts=$alerts" >> "$REPORT_FILE"
  log_message "ECS service report written to $REPORT_FILE (total_services=$total_services, alerts=$alerts)"
}

main "$@"
