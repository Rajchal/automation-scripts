#!/bin/bash

SERVER_LIST="servers.txt"
CMD="$1"
LOG="ssh_exec.log"

if [ -z "$CMD" ]; then
  echo "Usage: $0 'command to run'"
  exit 1
fi

echo "Running '$CMD' on all servers in $SERVER_LIST..."

while read -r server; do
  echo "=== $server ===" | tee -a "$LOG"
  ssh -o BatchMode=yes "$server" "$CMD" | tee -a "$LOG"
  echo "" | tee -a "$LOG"
done < "$SERVER_LIST"

echo "Execution completed. Output logged to $LOG."
