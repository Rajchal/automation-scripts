#!/bin/bash

EMAIL="admin@example.com"
STOPPED=$(docker ps -f "status=exited" --format "{{.Names}}")

if [ -n "$STOPPED" ]; then
  echo -e "Stopped containers detected:\n$STOPPED" | mail -s "Docker Alert on $(hostname)" "$EMAIL"
fi
