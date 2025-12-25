#!/usr/bin/env bash
set -euo pipefail

WAF_SCOPE=${WAF_SCOPE:-REGIONAL}
REGION=${REGION:-us-east-1}
PROFILE=${PROFILE:-}
LOOKBACK_HOURS=${LOOKBACK_HOURS:-6}
METRIC_PERIOD=${METRIC_PERIOD:-300}
ALERT_BLOCKED_RATE=${ALERT_BLOCKED_RATE:-5}
ALERT_BLOCKED_COUNT=${ALERT_BLOCKED_COUNT:-1000}
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL:-}
MAIL_TO=${MAIL_TO:-}
LOG_FILE=${LOG_FILE:-/var/log/aws-waf-web-acl-monitor.log}
REPORT_DIR=${REPORT_DIR:-/tmp}

if ! command -v aws >/dev/null 2>&1; then echo "aws CLI not found"; exit 1; fi
if ! command -v jq >/dev/null 2>&1; then echo "jq not found"; exit 1; fi

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
color() { case "$1" in red) tput setaf 1;; yellow) tput setaf 3;; green) tput setaf 2;; *) tput sgr0;; esac; }
reset() { tput sgr0; }
log() { printf "%s %s\n" "$(ts)" "$1" | tee -a "$LOG_FILE"; }
info() { color green; log "INFO  $1"; reset; }
warn() { color yellow; log "WARN  $1"; reset; }
err()  { color red; log "ERROR $1"; reset; }

slack_alert() {
  [ -z "$SLACK_WEBHOOK_URL" ] && return 0
  local title="$1"; local text="$2"; local color="#ff0000"
  curl -s -X POST -H 'Content-type: application/json' --data "$(jq -nc --arg t "$title" --arg x "$text" --arg c "$color" '{attachments:[{color:$c,title:$t,text:$x}]}}')" "$SLACK_WEBHOOK_URL" >/dev/null || true
}

email_alert() {
  [ -z "$MAIL_TO" ] && return 0
  local subject="$1"; local body="$2"
  printf "%s\n" "$body" | mail -s "$subject" "$MAIL_TO" || true
}

aws_cmd() {
  if [ -n "$PROFILE" ]; then AWS_PROFILE="$PROFILE" aws "$@"; else aws "$@"; fi
}

cloudwatch_region() {
  if [ "$WAF_SCOPE" = "CLOUDFRONT" ]; then echo "us-east-1"; else echo "$REGION"; fi
}

list_web_acls() {
  aws_cmd wafv2 list-web-acls --scope "$WAF_SCOPE" --region "$REGION" --output json \
    | jq -r '.WebACLs[]?|[.Name,.ARN,.Id] | @tsv'
}

get_web_acl_json() {
  local name="$1" id="$2"
  aws_cmd wafv2 get-web-acl --name "$name" --scope "$WAF_SCOPE" --id "$id" --region "$REGION" --output json
}

get_logging_json() {
  local arn="$1"
  aws_cmd wafv2 get-logging-configuration --resource-arn "$arn" --region "$REGION" --output json 2>/dev/null || true
}

metric_sum() {
  local web_acl="$1" metric="$2" rule="$3"
  local end_ts start_ts cw_region
  end_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  start_ts=$(date -u -d "-${LOOKBACK_HOURS} hours" +"%Y-%m-%dT%H:%M:%SZ")
  cw_region=$(cloudwatch_region)
  aws_cmd cloudwatch get-metric-statistics \
    --namespace "AWS/WAFV2" \
    --metric-name "$metric" \
    --dimensions Name=WebACL,Value="$web_acl" Name=Rule,Value="$rule" \
    --start-time "$start_ts" --end-time "$end_ts" \
    --period "$METRIC_PERIOD" --statistics Sum \
    --region "$cw_region" --output json \
    | jq -r '[.Datapoints[]?.Sum] | add // 0'
}

rule_names() {
  jq -r '.WebACL.Rules[]?.Name' | sed '/^$/d'
}

report_file="$REPORT_DIR/waf-web-acl-report-$(date -u +%Y%m%dT%H%M%SZ).txt"

info "Scope=$WAF_SCOPE Region=$REGION Lookback=${LOOKBACK_HOURS}h Period=${METRIC_PERIOD}s"

mapfile -t acls < <(list_web_acls || true)
if [ ${#acls[@]} -eq 0 ]; then warn "No Web ACLs found"; exit 0; fi

printf "AWS WAF Web ACL Report\nGenerated: %s\nScope: %s\nRegion: %s\n\n" "$(ts)" "$WAF_SCOPE" "$REGION" | tee -a "$report_file" >/dev/null

for row in "${acls[@]}"; do
  name=$(printf "%s" "$row" | awk '{print $1}')
  arn=$(printf "%s" "$row" | awk '{print $2}')
  id=$(printf "%s" "$row" | awk '{print $3}')

  info "Analyzing WebACL=$name"
  acl_json=$(get_web_acl_json "$name" "$id")
  capacity=$(printf "%s" "$acl_json" | jq -r '.WebACL.Capacity // 0')
  default_action=$(printf "%s" "$acl_json" | jq -r '.WebACL.DefaultAction | keys[0]')
  rules_count=$(printf "%s" "$acl_json" | jq -r '.WebACL.Rules | length')

  logging_json=$(get_logging_json "$arn")
  logging_enabled=$(printf "%s" "$logging_json" | jq -r '.LoggingConfiguration | if .==null then "false" else "true" end')

  allowed_total=$(metric_sum "$name" AllowedRequests ALL)
  blocked_total=$(metric_sum "$name" BlockedRequests ALL)
  counted_total=$(metric_sum "$name" CountedRequests ALL)

  total_req=$(echo "$allowed_total + $blocked_total" | bc)
  blocked_rate=0
  if [ "${total_req}" != "0" ]; then blocked_rate=$(echo "scale=4; ($blocked_total/$total_req)*100" | bc); fi

  printf "WebACL: %s\n" "$name" | tee -a "$report_file" >/dev/null
  printf "  Capacity: %s\n" "$capacity" | tee -a "$report_file" >/dev/null
  printf "  DefaultAction: %s\n" "$default_action" | tee -a "$report_file" >/dev/null
  printf "  Rules: %s\n" "$rules_count" | tee -a "$report_file" >/dev/null
  printf "  LoggingEnabled: %s\n" "$logging_enabled" | tee -a "$report_file" >/dev/null
  printf "  Metrics(lookback %sh): Allowed=%s Blocked=%s Counted=%s BlockedRate=%.2f%%\n" "$LOOKBACK_HOURS" "$allowed_total" "$blocked_total" "$counted_total" "$blocked_rate" | tee -a "$report_file" >/dev/null

  if [ "$logging_enabled" != "true" ]; then
    warn "Logging disabled for $name"
    slack_alert "WAF logging disabled: $name" "Enable WAFv2 logging for $name (scope=$WAF_SCOPE)."
    email_alert "WAF logging disabled: $name" "Enable WAFv2 logging for $name (scope=$WAF_SCOPE)."
  fi

  alert_triggered=false
  if [ "$(printf '%.0f' "$blocked_total")" -ge "$ALERT_BLOCKED_COUNT" ] || \
     [ "$(printf '%.2f' "$blocked_rate")" != "0.00" ] && \
     awk "BEGIN{exit !($blocked_rate >= $ALERT_BLOCKED_RATE)}"; then
    alert_triggered=true
  fi

  if [ "$alert_triggered" = true ]; then
    err "High blocked traffic on $name: rate=$(printf '%.2f' "$blocked_rate")%% count=$blocked_total"
    slack_alert "WAF high blocked traffic: $name" "BlockedRate=$(printf '%.2f' "$blocked_rate")%% Blocked=$blocked_total Allowed=$allowed_total"
    email_alert "WAF high blocked traffic: $name" "WebACL=$name\nBlockedRate=$(printf '%.2f' "$blocked_rate")%%\nBlocked=$blocked_total\nAllowed=$allowed_total\nScope=$WAF_SCOPE Region=$(cloudwatch_region)"
  else
    info "Blocked traffic within threshold for $name"
  fi

  rule_list=$(printf "%s" "$acl_json" | rule_names || true)
  if [ -n "$rule_list" ]; then
    printf "  Top rules by BlockedRequests:\n" | tee -a "$report_file" >/dev/null
    while read -r rname; do
      rblocked=$(metric_sum "$name" BlockedRequests "$rname")
      rallowed=$(metric_sum "$name" AllowedRequests "$rname")
      printf "    - %s: Blocked=%s Allowed=%s\n" "$rname" "$rblocked" "$rallowed" | tee -a "$report_file" >/dev/null
    done <<EOF
$(printf "%s" "$rule_list")
EOF
  fi

  printf "\n" | tee -a "$report_file" >/dev/null

done

info "Report saved: $report_file"