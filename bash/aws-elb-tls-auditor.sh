#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-elb-tls-auditor.log"
REPORT_FILE="/tmp/elb-tls-auditor-$(date +%Y%m%d%H%M%S).txt"
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
  echo "AWS ELB/ALB TLS Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_listener() {
  local lb_name="$1"
  local listener_arn="$2"
  local protocol="$3"

  echo "Listener: $listener_arn protocol=$protocol" >> "$REPORT_FILE"

  if [ "$protocol" = "HTTP" ]; then
    echo "  PROTOCOL_HTTP: $listener_arn accepts plain HTTP" >> "$REPORT_FILE"
    send_slack_alert "ELB Alert: $lb_name has an HTTP listener ($listener_arn)"
    return
  fi

  # describe listener to get SSL policy and certificates
  ljson=$(aws elbv2 describe-listeners --listener-arns "$listener_arn" --output json 2>/dev/null || echo '{}')
  certs=$(echo "$ljson" | jq -r '.Listeners[0].Certificates[]?.CertificateArn // empty' | tr '\n' ' ')
  ssl_policy=$(echo "$ljson" | jq -r '.Listeners[0].SslPolicy // empty')

  echo "  Certificates: ${certs:-none}" >> "$REPORT_FILE"
  echo "  SSL Policy: ${ssl_policy:-none}" >> "$REPORT_FILE"

  if [ -n "$ssl_policy" ]; then
    # flag legacy policies (heuristic)
    if echo "$ssl_policy" | grep -Eqi 'TLS-1-0|TLS1_0|TLSv1'; then
      echo "  INSECURE_SSL_POLICY: $ssl_policy" >> "$REPORT_FILE"
      send_slack_alert "ELB Alert: $lb_name listener $listener_arn uses insecure SSL policy $ssl_policy"
    fi
  else
    echo "  NO_SSL_POLICY" >> "$REPORT_FILE"
    send_slack_alert "ELB Alert: $lb_name listener $listener_arn has no SSL policy set"
  fi

  # check default actions: if HTTP redirect to HTTPS missing for HTTP->HTTPS listeners
}

main() {
  write_header

  aws elbv2 describe-load-balancers --output json 2>/dev/null | jq -c '.LoadBalancers[]? // empty' | while read -r lb; do
    name=$(echo "$lb" | jq -r '.LoadBalancerName')
    arn=$(echo "$lb" | jq -r '.LoadBalancerArn')
    typ=$(echo "$lb" | jq -r '.Type')
    scheme=$(echo "$lb" | jq -r '.Scheme')

    echo "LoadBalancer: $name arn=$arn type=$typ scheme=$scheme" >> "$REPORT_FILE"

    aws elbv2 describe-listeners --load-balancer-arn "$arn" --output json 2>/dev/null | jq -c '.Listeners[]? // empty' | while read -r lis; do
      listener_arn=$(echo "$lis" | jq -r '.ListenerArn')
      protocol=$(echo "$lis" | jq -r '.Protocol')
      check_listener "$name" "$listener_arn" "$protocol"
    done

    echo "" >> "$REPORT_FILE"
  done

  log_message "ELB TLS audit written to $REPORT_FILE"
}

main "$@"
