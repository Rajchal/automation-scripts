#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-elb-alb-tls-auditor.log"
REPORT_FILE="/tmp/elb-alb-tls-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
CERT_EXPIRY_WARN_DAYS="${ELB_CERT_EXPIRY_WARN_DAYS:-30}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "ELB/ALB TLS Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "Cert expiry warn days: $CERT_EXPIRY_WARN_DAYS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_acm_cert() {
  local arn="$1"
  if [ -z "$arn" ] || [ "$arn" = "null" ]; then
    return
  fi
  if echo "$arn" | grep -q "acm"; then
    cert=$(aws acm describe-certificate --certificate-arn "$arn" --output json 2>/dev/null || echo '{}')
    not_after=$(echo "$cert" | jq -r '.Certificate.NotAfter // empty')
    if [ -n "$not_after" ]; then
      not_after_epoch=$(date -d "$not_after" +%s 2>/dev/null || true)
      if [ -n "$not_after_epoch" ]; then
        days_left=$(( (not_after_epoch - $(date +%s)) / 86400 ))
        echo "    Cert: $arn expires in ${days_left}d ($not_after)" >> "$REPORT_FILE"
        if [ "$days_left" -le "$CERT_EXPIRY_WARN_DAYS" ]; then
          send_slack_alert "ELB/ALB Alert: Certificate $arn expires in ${days_left} days"
        fi
      fi
    fi
  fi
}

check_alb() {
  local lb_arn="$1"
  local lb_name="$2"
  local lb_dns="$3"
  echo "ALB: $lb_name ($lb_arn) dns=$lb_dns" >> "$REPORT_FILE"

  aws elbv2 describe-listeners --load-balancer-arn "$lb_arn" --output json 2>/dev/null | jq -c '.Listeners[]? // empty' | while read -r l; do
    port=$(echo "$l" | jq -r '.Port')
    proto=$(echo "$l" | jq -r '.Protocol')
    ssl_policy=$(echo "$l" | jq -r '.SslPolicy // empty')
    echo "  Listener port=$port proto=$proto ssl_policy=$ssl_policy" >> "$REPORT_FILE"

    if [ "$proto" != "HTTPS" ] && [ "$proto" != "TLS" ]; then
      if [ "$port" -eq 443 ] || [ "$port" -eq 8443 ]; then
        send_slack_alert "ELB/ALB Alert: Listener on $lb_name uses non-HTTPS protocol ($proto) on port $port"
      fi
    fi

    if [ -n "$ssl_policy" ]; then
      # flag old policies
      if echo "$ssl_policy" | grep -Ei "(TLSv1|TLSv1_0|SSLv3|ELBSecurityPolicy-2014|ELBSecurityPolicy-TLS-1-0)" >/dev/null 2>&1; then
        echo "    OLD_SSL_POLICY: $ssl_policy" >> "$REPORT_FILE"
        send_slack_alert "ELB/ALB Alert: $lb_name uses old SSL policy $ssl_policy"
      fi
    fi

    # check certificates
    echo "$l" | jq -c '.Certificates[]? // empty' | while read -r cert; do
      cert_arn=$(echo "$cert" | jq -r '.CertificateArn // empty')
      check_acm_cert "$cert_arn"
    done
  done

  echo "" >> "$REPORT_FILE"
}

check_classic_elb() {
  local name="$1"
  echo "Classic ELB: $name" >> "$REPORT_FILE"
  aws elb describe-load-balancers --load-balancer-names "$name" --output json 2>/dev/null | jq -c '.LoadBalancerDescriptions[]? // empty' | while read -r d; do
    echo "  Listeners:" >> "$REPORT_FILE"
    echo "$d" | jq -c '.ListenerDescriptions[]? | .Listener' | while read -r lst; do
      protocol=$(echo "$lst" | jq -r '.Protocol')
      lb_port=$(echo "$lst" | jq -r '.LoadBalancerPort')
      ssl_cert_id=$(echo "$lst" | jq -r '.SSLCertificateId // empty')
      echo "    protocol=$protocol port=$lb_port cert=$ssl_cert_id" >> "$REPORT_FILE"
      if [ "$protocol" = "SSL" ] || [ "$protocol" = "HTTPS" ]; then
        # try IAM cert parse or skip
        if echo "$ssl_cert_id" | grep -q "arn:aws:acm"; then
          check_acm_cert "$ssl_cert_id"
        fi
      else
        if [ "$lb_port" -eq 443 ]; then
          send_slack_alert "ELB Alert: Classic ELB $name has non-HTTPS listener on port 443 (protocol=$protocol)"
        fi
      fi
    done
  done
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  # ALBs/NLBs (elbv2)
  aws elbv2 describe-load-balancers --output json 2>/dev/null | jq -c '.LoadBalancers[]? // empty' | while read -r lb; do
    arn=$(echo "$lb" | jq -r '.LoadBalancerArn')
    name=$(echo "$lb" | jq -r '.LoadBalancerName')
    dns=$(echo "$lb" | jq -r '.DNSName // empty')
    type=$(echo "$lb" | jq -r '.Type // empty')
    if [ "$type" = "application" ] || [ "$type" = "network" ]; then
      check_alb "$arn" "$name" "$dns"
    fi
  done

  # Classic ELBs
  aws elb describe-load-balancers --output json 2>/dev/null | jq -c '.LoadBalancerDescriptions[]? // empty' | while read -r d; do
    name=$(echo "$d" | jq -r '.LoadBalancerName')
    check_classic_elb "$name"
  done

  log_message "ELB/ALB TLS audit written to $REPORT_FILE"
}

main "$@"
