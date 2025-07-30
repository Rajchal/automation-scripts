#!/bin/bash

NAME="$1"
LOG="/var/log/kill_${NAME}_$(date +%F).log"

if [ -z "$NAME" ]; then
  echo "Usage: $0 processname"
  exit 1
fi

PIDS=$(pgrep "$NAME")
if [ -z "$PIDS" ]; then
  echo "No processes named $NAME found."
  exit 0
fi

for pid in $PIDS; do
  echo "Killing $NAME with PID $pid" | tee -a "$LOG"
  kill "$pid"
done

echo "All $NAME processes killed. Details logged to $LOG."
