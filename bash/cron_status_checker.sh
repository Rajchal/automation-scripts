#!/bin/bash

for user in $(cut -f1 -d: /etc/passwd); do
  echo "User: $user"
  crontab -u "$user" -l 2>/dev/null || echo "No crontab for $user"
done
