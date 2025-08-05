#!/bin/bash

THRESHOLD=0
for user in $(awk -F: '{if ($7 != "/usr/sbin/nologin" && $7 != "/bin/false") print $1}' /etc/passwd); do
  EXPIRED=$(chage -l "$user" 2>/dev/null | grep "Account expires" | grep -v "never" | awk -F: '{print $2}' | xargs -I{} date -d "{}" +%s 2>/dev/null)
  NOW=$(date +%s)
  if [ -n "$EXPIRED" ] && [ "$EXPIRED" -lt "$NOW" ]; then
    usermod -L "$user"
    echo "Locked expired user: $user"
  fi
done
