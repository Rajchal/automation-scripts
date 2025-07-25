#!/bin/bash

HOSTS=("8.8.8.8" "github.com" "example.com")
LOG="ping_report_$(date +%F).log"

echo "Ping results for $(date):" > "$LOG"

for host in "${HOSTS[@]}"; do
    echo -n "$host: " | tee -a "$LOG"
    ping -c 3 -q "$host" | awk -F'/' 'END {print $(NF-1)" ms avg"}' | tee -a "$LOG"
done

echo "Results saved to $LOG"
