#!/usr/bin/env bash
set -euo pipefail

# docker-compose-policy-auditor.sh
# Audit Docker Compose services for reliability and security baseline policies.

usage() {
  cat <<EOF
Usage: $0 [--file FILE] [--project-dir DIR] [--output text|json] [--no-fail]

Options:
  --file FILE         Compose file path (default: docker-compose.yml)
  --project-dir DIR   Compose project directory (default: current directory)
  --output FORMAT     text (default) or json
  --no-fail           Exit 0 even if findings are present
  -h, --help          Show this help

Checks:
  - Image uses :latest tag
  - Image tag missing (implicit latest)
  - Missing restart policy
  - Missing healthcheck
  - Running container as root user (user: "0" or "root")

Examples:
  bash/docker-compose-policy-auditor.sh
  bash/docker-compose-policy-auditor.sh --file compose.prod.yml --project-dir app
  bash/docker-compose-policy-auditor.sh --output json --no-fail
EOF
}

FILE="docker-compose.yml"
PROJECT_DIR="."
OUTPUT="text"
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE="${2:-}"; shift 2 ;;
    --project-dir) PROJECT_DIR="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --no-fail) NO_FAIL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "json" ]]; then
  echo "--output must be text or json" >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker CLI is required" >&2
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 3
fi

compose_json="$(
  docker compose \
    --project-directory "$PROJECT_DIR" \
    -f "$FILE" \
    config --format json 2>/dev/null || true
)"

if [[ -z "$compose_json" ]]; then
  echo "Unable to parse compose file: $PROJECT_DIR/$FILE" >&2
  echo "Tip: validate with 'docker compose -f $FILE config'" >&2
  exit 4
fi

service_count="$(jq '.services | keys | length' <<< "$compose_json")"

findings_json="$(jq -c '
  .services as $services
  | [
      ($services | to_entries[] | .key as $svc | .value as $v
        | (if ($v.image // "") == "" then
             {service:$svc, issue:"missing_image", detail:"service has no image (may require build)"}
           else empty end),
          (if (($v.image // "") | test(":latest$")) then
             {service:$svc, issue:"latest_tag", detail:($v.image // "")}
           else empty end),
          (if (($v.image // "") != "" and (($v.image // "") | test(":") | not)) then
             {service:$svc, issue:"untagged_image", detail:($v.image // "")}
           else empty end),
          (if ($v.restart == null or ($v.restart|tostring)=="") then
             {service:$svc, issue:"missing_restart_policy", detail:"restart not configured"}
           else empty end),
          (if $v.healthcheck == null then
             {service:$svc, issue:"missing_healthcheck", detail:"healthcheck not configured"}
           else empty end),
          (if (($v.user // "")|tostring|ascii_downcase) == "root" or (($v.user // "")|tostring) == "0" then
             {service:$svc, issue:"runs_as_root", detail:("user=" + (($v.user // "")|tostring))}
           else empty end)
      )
    ] | map(select(. != null))
' <<< "$compose_json")"

finding_count="$(jq 'length' <<< "$findings_json")"

if [[ "$OUTPUT" == "json" ]]; then
  jq -n \
    --arg file "$FILE" \
    --arg project_dir "$PROJECT_DIR" \
    --argjson service_count "$service_count" \
    --argjson findings "$findings_json" \
    '{file:$file, project_dir:$project_dir, service_count:$service_count, findings:$findings}'
else
  echo "Docker Compose Policy Auditor"
  echo "Project dir: $PROJECT_DIR"
  echo "Compose file: $FILE"
  echo "Services: $service_count"
  echo ""

  if [[ "$finding_count" -eq 0 ]]; then
    echo "No policy findings."
  else
    echo "Findings: $finding_count"
    jq -r '.[] | "- [\(.issue)] service=\(.service) detail=\(.detail)"' <<< "$findings_json"
  fi
fi

if [[ "$finding_count" -gt 0 && "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
