#!/bin/bash
for user in $(cut -f1 -d: /etc/passwd); do
    echo "Cron jobs for $user:"
    crontab -u $user -l 2>/dev/null
done
