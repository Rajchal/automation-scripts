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
