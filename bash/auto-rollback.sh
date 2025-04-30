#!/bin/bash

# Bash script for automated rollback in case of deployment failure
set -e

DEPLOY_LOG="/var/log/deploy.log"
ROLLBACK_SCRIPT="/path/to/rollback.sh"

echo "Monitoring deployment logs..."

# Monitor logs for "deployment failed" messages
tail -F $DEPLOY_LOG | while read LINE; do
  if echo "$LINE" | grep -q "deployment failed"; then
    echo "Deployment failed! Initiating rollback..."
    bash $ROLLBACK_SCRIPT
    exit 1
  fi
done
