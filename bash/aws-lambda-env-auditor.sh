#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-lambda-env-auditor.log"
REPORT_FILE="/tmp/lambda-env-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MAX_TIMEOUT="${LAMBDA_MAX_TIMEOUT:-300}"
MIN_MEMORY="${LAMBDA_MIN_MEMORY:-128}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS Lambda Environment Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "Max timeout warn: ${MAX_TIMEOUT}s" >> "$REPORT_FILE"
  echo "Min memory recommended: ${MIN_MEMORY}MB" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

deprecated_runtime() {
  case "$1" in
    nodejs|nodejs0.10|nodejs4.3|nodejs6.10|python2.7|java6|dotnetcore1.0) return 0 ;;
    *) return 1 ;;
  esac
}

check_function() {
  local name="$1"
  cfg_json=$(aws lambda get-function-configuration --function-name "$name" --output json 2>/dev/null || echo '{}')
  if [ -z "$cfg_json" ] || [ "$cfg_json" = "{}" ]; then
    echo "Function: $name - unable to describe" >> "$REPORT_FILE"
    return
  fi

  runtime=$(echo "$cfg_json" | jq -r '.Runtime // ""')
  timeout=$(echo "$cfg_json" | jq -r '.Timeout // 0')
  memory=$(echo "$cfg_json" | jq -r '.MemorySize // 0')
  vpc=$(echo "$cfg_json" | jq -c '.VpcConfig // {}')
  role=$(echo "$cfg_json" | jq -r '.Role // ""')
  layers=$(echo "$cfg_json" | jq -r '.Layers // [] | length')
  envs=$(echo "$cfg_json" | jq -c '.Environment.Variables // {}')

  echo "Function: $name runtime=$runtime timeout=${timeout}s memory=${memory}MB role=$role layers=$layers" >> "$REPORT_FILE"

  # runtime
  if deprecated_runtime "$runtime"; then
    echo "  DEPRECATED_RUNTIME: $runtime" >> "$REPORT_FILE"
    send_slack_alert "Lambda Alert: Function $name uses deprecated runtime $runtime"
  fi

  # timeout
  if [ "$timeout" -gt "$MAX_TIMEOUT" ]; then
    echo "  TIMEOUT_HIGH: ${timeout}s > ${MAX_TIMEOUT}s" >> "$REPORT_FILE"
    send_slack_alert "Lambda Alert: Function $name has timeout ${timeout}s (>${MAX_TIMEOUT}s)"
  fi

  # memory
  if [ "$memory" -lt "$MIN_MEMORY" ]; then
    echo "  LOW_MEMORY: ${memory}MB < ${MIN_MEMORY}MB" >> "$REPORT_FILE"
    send_slack_alert "Lambda Notice: Function $name memory ${memory}MB is below recommended ${MIN_MEMORY}MB"
  fi

  # VPC check
  vpc_subnets=$(echo "$vpc" | jq -r '.SubnetIds // [] | length')
  if [ "$vpc_subnets" -eq 0 ]; then
    echo "  NOT_IN_VPC: function not attached to VPC" >> "$REPORT_FILE"
  else
    echo "  VPC_SUBNETS: $vpc_subnets" >> "$REPORT_FILE"
  fi

  # environment variable name checks
  echo "$envs" | jq -r 'to_entries[]? | .key' | while read -r k; do
    if echo "$k" | grep -Ei "PASSWORD|SECRET|TOKEN|KEY|AWS_SECRET|ACCESS_KEY" >/dev/null 2>&1; then
      echo "  POSSIBLE_PLAINTEXT_SECRET_ENV: $k" >> "$REPORT_FILE"
      send_slack_alert "Lambda Alert: Function $name has environment variable named $k (possible secret)"
    fi
  done

  # check for large number of layers
  if [ "$layers" -gt 5 ]; then
    echo "  MANY_LAYERS: $layers" >> "$REPORT_FILE"
    send_slack_alert "Lambda Notice: Function $name attaches $layers layers"
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header
  aws lambda list-functions --output json 2>/dev/null | jq -r '.Functions[]?.FunctionName' | while read -r fn; do
    check_function "$fn"
  done

  log_message "Lambda environment audit written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-lambda-env-auditor.log"
REPORT_FILE="/tmp/lambda-env-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
ENV_SECRET_PATTERNS='PASSWORD|SECRET|TOKEN|KEY|AWS_SECRET|PRIVATE'
MEMORY_THRESHOLD="${LAMBDA_MEMORY_WARN:-128}"
TIMEOUT_THRESHOLD="${LAMBDA_TIMEOUT_WARN:-30}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS Lambda Environment Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "Memory warn (MB): $MEMORY_THRESHOLD Timeout warn (s): $TIMEOUT_THRESHOLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_function() {
  local fname="$1"
  cfg=$(aws lambda get-function-configuration --function-name "$fname" --output json 2>/dev/null || echo '{}')
  handler=$(echo "$cfg" | jq -r '.Handler // ""')
  runtime=$(echo "$cfg" | jq -r '.Runtime // ""')
  mem=$(echo "$cfg" | jq -r '.MemorySize // 0')
  timeout=$(echo "$cfg" | jq -r '.Timeout // 0')
  role=$(echo "$cfg" | jq -r '.Role // ""')
  envs=$(echo "$cfg" | jq -c '.Environment.Variables // {}')

  echo "Function: $fname runtime=$runtime handler=$handler memory=${mem}MB timeout=${timeout}s role=${role}" >> "$REPORT_FILE"

  if [ "$mem" -lt "$MEMORY_THRESHOLD" ]; then
    echo "  LOW_MEMORY: ${mem}MB < ${MEMORY_THRESHOLD}MB" >> "$REPORT_FILE"
    send_slack_alert "Lambda Notice: $fname memory ${mem}MB < ${MEMORY_THRESHOLD}MB"
  fi
  if [ "$timeout" -lt "$TIMEOUT_THRESHOLD" ]; then
    echo "  SHORT_TIMEOUT: ${timeout}s < ${TIMEOUT_THRESHOLD}s" >> "$REPORT_FILE"
    send_slack_alert "Lambda Notice: $fname timeout ${timeout}s < ${TIMEOUT_THRESHOLD}s"
  fi

  # environment variable checks
  if [ "$(echo "$envs" | jq 'length')" -eq 0 ]; then
    echo "  NO_ENV_VARS" >> "$REPORT_FILE"
  else
    echo "$envs" | jq -r 'to_entries[] | "    \(.key)=\(.value)"' >> "$REPORT_FILE"
    echo "$envs" | jq -r 'keys[]' | while read -r key; do
      if echo "$key" | grep -Ei "$ENV_SECRET_PATTERNS" >/dev/null 2>&1; then
        echo "  POSSIBLE_SECRET_IN_ENV: $key" >> "$REPORT_FILE"
        send_slack_alert "Lambda Alert: $fname has environment variable named $key (possible secret)"
      fi
    done
  fi

  # check reserved concurrency
  conc=$(aws lambda get-function-concurrency --function-name "$fname" --output json 2>/dev/null || echo '{}')
  if echo "$conc" | jq -e 'has("ReservedConcurrentExecutions")' >/dev/null 2>&1; then
    rce=$(echo "$conc" | jq -r '.ReservedConcurrentExecutions')
    echo "  ReservedConcurrency=$rce" >> "$REPORT_FILE"
  else
    echo "  ReservedConcurrency=UNSET" >> "$REPORT_FILE"
  fi

  # check function URL (public endpoints)
  if aws lambda get-function-url-config --function-name "$fname" --output json >/dev/null 2>&1; then
    urlcfg=$(aws lambda get-function-url-config --function-name "$fname" --output json 2>/dev/null || echo '{}')
    auth=$(echo "$urlcfg" | jq -r '.AuthType // "NONE"')
    echo "  FunctionURL authType=$auth" >> "$REPORT_FILE"
    if [ "$auth" = "NONE" ]; then
      echo "  PUBLIC_FUNCTION_URL_NO_AUTH" >> "$REPORT_FILE"
      send_slack_alert "Lambda Alert: $fname has a Function URL with no auth (public)"
    fi
  fi

  # heuristic: role name contains Admin
  if echo "$role" | grep -Ei "admin|administrator|poweruser" >/dev/null 2>&1; then
    echo "  ROLE_MAY_BE_PRIVILEGED: $role" >> "$REPORT_FILE"
    send_slack_alert "Lambda Notice: $fname role ($role) contains admin-like name"
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header
  aws lambda list-functions --output json 2>/dev/null | jq -r '.Functions[]?.FunctionName // empty' | while read -r f; do
    check_function "$f"
  done
  log_message "Lambda env audit written to $REPORT_FILE"
}

main "$@"
