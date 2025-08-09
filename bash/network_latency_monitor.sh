#!/bin/bash
# Monitors network latency to a list of hosts and alerts if latency exceeds threshold

HOSTS=("8.8.8.8" "github.com" "example.com")
THRESHOLD=100 # ms

for host in "${HOSTS[@]}"; do
  AVG=$(ping -c 4 "$host" | tail -1 | awk '{print $4}' | cut -d '/' -f 2)
  if (( $(echo "$AVG > $THRESHOLD" | bc -l) )); then
    echo "ALERT: High latency to $host: ${AVG}ms"
  fi
done
