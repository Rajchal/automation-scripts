#!/bin/bash

WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
REPORT="/tmp/update_report_$(date +%F).txt"

apt update > "$REPORT"
UPGRADES=$(apt list --upgradable 2>/dev/null | grep -v Listing)

if [ -n "$UPGRADES" ]; then
  echo "Upgradable packages:" >> "$REPORT"
  echo "$UPGRADES" >> "$REPORT"
  curl -X POST -H 'Content-type: application/json' --data "{\"text\":\"$(hostname) has updates available:\n$UPGRADES\"}" "$WEBHOOK_URL"
else
  echo "No upgrades available." >> "$REPORT"
fi

echo "Update report saved to $REPORT"
