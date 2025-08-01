#!/bin/bash

ALLOWED_PORTS="22 80 443"
EMAIL="admin@example.com"
LISTENING=$(ss -tuln | awk 'NR>1{split($5, a, ":"); print a[length(a)]}' | sort -n | uniq)

for port in $LISTENING; do
  if ! echo "$ALLOWED_PORTS" | grep -wq "$port"; then
    echo "Unexpected open port: $port on $(hostname)" | mail -s "Port Alert" "$EMAIL"
  fi
done
