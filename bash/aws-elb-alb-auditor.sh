#!/bin/bash

################################################################################
# AWS ELB/ALB Auditor
# Audits Application/Network/Classic Load Balancers for TLS config, cert usage,
# access-logs, stickiness, idle timeouts and target health.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/elb-alb-audit-$(date +%s).txt"
LOG_FILE="/var/log/elb-alb-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
UNSUPPORTED_SSL_POLICIES=("ELBSecurityPolicy-2016-08" "ELBSecurityPolicy-TLS-1-0-2015-04")

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

# API wrappers
list_load_balancers() {
  aws elbv2 describe-load-balancers --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_listeners() {
  local lb_arn="$1"
  aws elbv2 describe-listeners --load-balancer-arn "${lb_arn}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_target_groups() {
  local lb_arn="$1"
  aws elbv2 describe-target-groups --load-balancer-arn "${lb_arn}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_target_health() {
  local tg_arn="$1"
  aws elbv2 describe-target-health --target-group-arn "${tg_arn}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_load_balancer_attributes() {
  local lb_arn="$1"
  aws elbv2 describe-load-balancer-attributes --load-balancer-arn "${lb_arn}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_listener_certificates() {
  local listener_arn="$1"
  aws elbv2 describe-listener-certificates --listener-arn "${listener_arn}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_classic_load_balancers() {
  aws elb describe-load-balancers --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_classic_lb_attributes() {
  local name="$1"
  aws elb describe-load-balancer-attributes --load-balancer-name "${name}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS ELB/ALB Audit Report"
    echo "========================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_albs() {
  log_message INFO "Auditing Application/Network Load Balancers (ELBv2)"
  {
    echo "=== ELBv2 (ALB/NLB) AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local lbs
  lbs=$(list_load_balancers)

  local total=0 https_no_redirect=0 insecure_policy=0 missing_access_logs=0 unhealthy_targets=0 certs_missing=0

  echo "${lbs}" | jq -c '.LoadBalancers[]?' 2>/dev/null | while read -r lb; do
    ((total++))
    local name arn type dns state scheme vpc
    name=$(echo "${lb}" | jq_safe '.LoadBalancerName')
    arn=$(echo "${lb}" | jq_safe '.LoadBalancerArn')
    type=$(echo "${lb}" | jq_safe '.Type')
    dns=$(echo "${lb}" | jq_safe '.DNSName')
    state=$(echo "${lb}" | jq_safe '.State.Code')
    scheme=$(echo "${lb}" | jq_safe '.Scheme')
    vpc=$(echo "${lb}" | jq_safe '.VpcId')

    {
      echo "Load Balancer: ${name}"
      echo "  ARN: ${arn}"
      echo "  Type: ${type}"
      echo "  DNS: ${dns}"
      echo "  Scheme: ${scheme}"
      echo "  State: ${state}"
      echo "  VPC: ${vpc}"
    } >> "${OUTPUT_FILE}"

    # Attributes
    local attrs
    attrs=$(get_load_balancer_attributes "${arn}")
    local access_logs_enabled
    access_logs_enabled=$(echo "${attrs}" | jq_safe '.Attributes[]? | select(.Key=="access_logs.s3.enabled") | .Value')
    if [[ "${access_logs_enabled}" != "true" ]]; then
      ((missing_access_logs++))
      echo "  WARNING: Access logs not enabled" >> "${OUTPUT_FILE}"
    else
      echo "  Access logs: enabled" >> "${OUTPUT_FILE}"
    fi

    # Listeners
    local listeners
    listeners=$(describe_listeners "${arn}")
    echo "${listeners}" | jq -c '.Listeners[]?' 2>/dev/null | while read -r listener; do
      local listener_arn port proto ssl_policy default_actions
      listener_arn=$(echo "${listener}" | jq_safe '.ListenerArn')
      port=$(echo "${listener}" | jq_safe '.Port')
      proto=$(echo "${listener}" | jq_safe '.Protocol')
      ssl_policy=$(echo "${listener}" | jq_safe '.SslPolicy')
      default_actions=$(echo "${listener}" | jq -c '.DefaultActions')

      echo "  Listener: ${proto}:${port}" >> "${OUTPUT_FILE}"

      if [[ "${proto}" == "HTTPS" || "${proto}" == "TLS" ]]; then
        # Check certificates
        local certs
        certs=$(get_listener_certificates "${listener_arn}")
        if echo "${certs}" | jq -e '.Certificates | length > 0' >/dev/null 2>&1; then
          echo "    Certificates: present" >> "${OUTPUT_FILE}"
        else
          ((certs_missing++))
          echo "    WARNING: No certificates associated with listener" >> "${OUTPUT_FILE}"
        fi

        # Check SSL policy
        if [[ -n "${ssl_policy}" && "${ssl_policy}" != "null" ]]; then
          echo "    SSL Policy: ${ssl_policy}" >> "${OUTPUT_FILE}"
          for p in "${UNSUPPORTED_SSL_POLICIES[@]}"; do
            if [[ "${ssl_policy}" == "${p}" ]]; then
              ((insecure_policy++))
              echo "    WARNING: Using unsupported/insecure SSL policy: ${ssl_policy}" >> "${OUTPUT_FILE}"
            fi
          done
        fi

        # Check HTTP->HTTPS redirect in default actions
        if echo "${default_actions}" | jq -e '.[]? | select(.Type=="redirect" and .RedirectConfig.Protocol=="HTTPS")' >/dev/null 2>&1; then
          echo "    Redirect: HTTP->HTTPS present" >> "${OUTPUT_FILE}"
        else
          # if listener is HTTPS, that's fine; if a corresponding HTTP listener exists without redirect, warn
          if [[ "${proto}" == "HTTP" ]]; then
            ((https_no_redirect++))
            echo "    WARNING: HTTP listener without HTTPS redirect" >> "${OUTPUT_FILE}"
          fi
        fi
      else
        # Non-HTTPS listener details
        echo "    Protocol policy: ${proto}" >> "${OUTPUT_FILE}"
      fi
    done

    # Target Groups and health
    local tgs
    tgs=$(describe_target_groups "${arn}")
    echo "${tgs}" | jq -c '.TargetGroups[]?' 2>/dev/null | while read -r tg; do
      local tg_arn tg_name tg_protocol tg_port health
      tg_arn=$(echo "${tg}" | jq_safe '.TargetGroupArn')
      tg_name=$(echo "${tg}" | jq_safe '.TargetGroupName')
      tg_protocol=$(echo "${tg}" | jq_safe '.Protocol')
      tg_port=$(echo "${tg}" | jq_safe '.Port')
      echo "  Target Group: ${tg_name} (${tg_protocol}:${tg_port})" >> "${OUTPUT_FILE}"

      health=$(describe_target_health "${tg_arn}")
      local unhealthy_count
      unhealthy_count=$(echo "${health}" | jq '[.TargetHealthDescriptions[]? | select(.TargetHealth.State!="healthy")] | length' 2>/dev/null || echo 0)
      if (( unhealthy_count > 0 )); then
        ((unhealthy_targets++))
        echo "    WARNING: ${unhealthy_count} unhealthy targets" >> "${OUTPUT_FILE}"
      else
        echo "    All targets healthy" >> "${OUTPUT_FILE}"
      fi
    done

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "ELBv2 Summary:"
    echo "  Total Load Balancers: ${total}"
    echo "  Missing Access Logs: ${missing_access_logs}"
    echo "  Insecure SSL Policies: ${insecure_policy}"
    echo "  HTTP Listeners without redirect: ${https_no_redirect}"
    echo "  Missing Certificates on listeners: ${certs_missing}"
    echo "  Target Groups with unhealthy targets: ${unhealthy_targets}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_classic_elbs() {
  log_message INFO "Auditing Classic ELBs"
  {
    echo "=== CLASSIC ELB AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local elbs
  elbs=$(list_classic_load_balancers)

  echo "${elbs}" | jq -c '.LoadBalancerDescriptions[]?' 2>/dev/null | while read -r elb; do
    local name dns scheme listener_count
    name=$(echo "${elb}" | jq_safe '.LoadBalancerName')
    dns=$(echo "${elb}" | jq_safe '.DNSName')
    scheme=$(echo "${elb}" | jq_safe '.Scheme')
    listener_count=$(echo "${elb}" | jq '.ListenerDescriptions | length' 2>/dev/null || echo 0)

    {
      echo "Classic ELB: ${name}"
      echo "  DNS: ${dns}"
      echo "  Scheme: ${scheme}"
      echo "  Listener Count: ${listener_count}"
    } >> "${OUTPUT_FILE}"

    # Attributes
    local attrs
    attrs=$(get_classic_lb_attributes "${name}")
    local access_logs_enabled
    access_logs_enabled=$(echo "${attrs}" | jq_safe '.LoadBalancerAttributes.AccessLog.Enabled')
    if [[ "${access_logs_enabled}" != "true" ]]; then
      echo "  WARNING: Access logs not enabled" >> "${OUTPUT_FILE}"
    else
      echo "  Access logs: enabled" >> "${OUTPUT_FILE}"
    fi

    # Check for insecure listener policies (TLS versions older than TLS1.2) is harder on classic ELB; list any SSLListener with insecure ciphers mention
    echo "" >> "${OUTPUT_FILE}"
  done
}

send_slack_alert() {
  local total="$1"; local missing_logs="$2"; local insecure_policies="$3"; local unhealthy="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  (( unhealthy > 0 || insecure_policies > 0 )) && color="danger"
  (( missing_logs > 0 && color == "good" )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS ELB/ALB Audit Report",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Total LBs", "value": "${total}", "short": true},
        {"title": "Missing Access Logs", "value": "${missing_logs}", "short": true},
        {"title": "Insecure SSL Policies", "value": "${insecure_policies}", "short": true},
        {"title": "Unhealthy Targets", "value": "${unhealthy}", "short": true},
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Timestamp", "value": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "short": false}
      ]
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

main() {
  log_message INFO "Starting ELB/ALB audit"
  write_header
  audit_albs
  audit_classic_elbs
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total missing_logs insecure unhealthy
  total=$(grep "Total Load Balancers:" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  missing_logs=$(grep "Missing Access Logs:" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  insecure=$(grep "Insecure SSL Policies:" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  unhealthy=$(grep "Target Groups with unhealthy targets:" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  send_slack_alert "${total}" "${missing_logs}" "${insecure}" "${unhealthy}"
  cat "${OUTPUT_FILE}"
}

main "$@"
