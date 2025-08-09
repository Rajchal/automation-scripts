#!/bin/bash
# Monitors failed SSH logins and sends an alert if more than 10 in the last hour

EMAIL="admin@example.com"
COUNT=$(grep "Failed password" /var/log/auth.log | grep "$(date +"%b %_d %H")" | wc -l)
if [ "$COUNT" -gt 10 ]; then
  echo "There have been $COUNT failed SSH logins in the last hour on $(hostname)" | mail -s "Failed SSH Login Alert" "$EMAIL"
fi
