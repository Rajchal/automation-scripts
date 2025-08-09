#!/bin/bash
# Checks GitLab runners and restarts if not healthy

RUNNERS=("gitlab-runner-1" "gitlab-runner-2")
for runner in "${RUNNERS[@]}"; do
  systemctl is-active --quiet "$runner" || {
    echo "Restarting $runner..."
    systemctl restart "$runner"
  }
done
