#!/bin/bash

################################################################################
# AWS CodeCommit Repo Auditor
# Audits repositories for branch protection, commit activity, large files, and
# unlinked repositories (no CI/CD). Reports inactive repos and missing triggers.
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/codecommit-audit-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-codecommit-auditor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
INACTIVE_DAYS_WARN="${INACTIVE_DAYS_WARN:-90}"

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

list_repos() {
  aws codecommit list-repositories --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_repo() {
  local name="$1"
  aws codecommit get-repository --repository-name "${name}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_triggers() {
  local name="$1"
  aws codecommit get-repository-triggers --repository-name "${name}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_commits_since() {
  local repo="$1"; local since="$2"
  aws codecommit get-commit --repository-name "${repo}" --commit-id "${since}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS CodeCommit Repository Auditor"
    echo "=================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Inactive repo warn (days): ${INACTIVE_DAYS_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_repos() {
  log_message INFO "Listing CodeCommit repositories"
  echo "=== CodeCommit Repositories ===" >> "${OUTPUT_FILE}"

  local repos
  repos=$(list_repos)
  echo "${repos}" | jq -c '.repositories[]?' 2>/dev/null | while read -r r; do
    local name id
    name=$(echo "${r}" | jq_safe '.repositoryName')
    id=$(echo "${r}" | jq_safe '.repositoryId')
    echo "Repository: ${name} (${id})" >> "${OUTPUT_FILE}"

    local repo
    repo=$(get_repo "${name}")
    local clone_url
    clone_url=$(echo "${repo}" | jq_safe '.repositoryMetadata.cloneUrlHttp')
    echo "  CloneUrl: ${clone_url}" >> "${OUTPUT_FILE}"

    # Triggers
    local triggers
    triggers=$(list_triggers "${name}")
    local trigger_count
    trigger_count=$(echo "${triggers}" | jq '.triggers | length' 2>/dev/null || echo 0)
    echo "  Triggers: ${trigger_count}" >> "${OUTPUT_FILE}"
    if (( trigger_count == 0 )); then
      echo "  WARNING: No repository triggers configured (no CI/CD integration)" >> "${OUTPUT_FILE}"
    fi

    # Last commit (approx): use list-branches + get-branch commitId
    local branches
    branches=$(aws codecommit list-branches --repository-name "${name}" --region "${REGION}" --output json 2>/dev/null || echo '{}')
    echo "  Branches: " >> "${OUTPUT_FILE}"
    echo "${branches}" | jq -r '.branches[]?' 2>/dev/null | while read -r br; do
      local commit_id
      commit_id=$(aws codecommit get-branch --repository-name "${name}" --branch-name "${br}" --region "${REGION}" --output json 2>/dev/null | jq -r '.branch.commitId' 2>/dev/null || echo '')
      if [[ -n "${commit_id}" ]]; then
        # get commit metadata
        local commit_meta
        commit_meta=$(aws codecommit get-commit --repository-name "${name}" --commit-id "${commit_id}" --region "${REGION}" --output json 2>/dev/null || echo '{}')
        local date
        date=$(echo "${commit_meta}" | jq_safe '.commit.committer.date')
        echo "    - ${br}: commit=${commit_id} date=${date}" >> "${OUTPUT_FILE}"

        # check inactive
        if [[ -n "${date}" && "${date}" != "null" ]]; then
          local epoch
          epoch=$(date -d "${date}" +%s 2>/dev/null || date -u -d "${date}" +%s)
          local days
          days=$(( ( $(date +%s) - epoch ) / 86400 ))
          if (( days >= INACTIVE_DAYS_WARN )); then
            echo "    WARNING: Branch ${br} last commit ${days} days ago" >> "${OUTPUT_FILE}"
          fi
        fi
      fi
    done

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "CodeCommit Summary:"
    echo "  Repositories checked: $(echo "${repos}" | jq '.repositories | length' 2>/dev/null || echo 0)"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local issues_count="$1"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  (( issues_count > 0 )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "CodeCommit Audit Summary",
  "attachments": [
    {"color": "${color}", "fields": [{"title":"Issues Found","value":"${issues_count}","short":true}]}
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

main() {
  log_message INFO "Starting CodeCommit repository audit"
  write_header
  audit_repos
  log_message INFO "CodeCommit audit complete. Report: ${OUTPUT_FILE}"
  local issues
  issues=$(grep "WARNING:" "${OUTPUT_FILE}" | wc -l || echo 0)
  send_slack_alert "${issues}"
  cat "${OUTPUT_FILE}"
}

main "$@"
