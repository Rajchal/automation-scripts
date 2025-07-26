#!/bin/bash

OUTDIR="/var/log/sys_snapshots"
mkdir -p "$OUTDIR"
FILE="$OUTDIR/snapshot_$(date +%F_%H%M%S).txt"

{
  echo "=== Snapshot: $(date) ==="
  echo "--- Uptime ---"
  uptime
  echo "--- Disk Usage ---"
  df -h
  echo "--- Memory Usage ---"
  free -h
  echo "--- Top CPU Processes ---"
  ps aux --sort=-%cpu | head -n 10
  echo "--- Top Memory Processes ---"
  ps aux --sort=-%mem | head -n 10
  echo "--- Network Interfaces ---"
  ip addr
  echo "--- Listening Ports ---"
  ss -tulnp
  echo "--- Recent Reboots ---"
  last reboot | head -n 5
} > "$FILE"

echo "Snapshot saved to $FILE"
