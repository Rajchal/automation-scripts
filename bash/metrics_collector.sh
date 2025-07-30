#!/bin/bash

OUTDIR="/var/log/metrics"
mkdir -p "$OUTDIR"
NOW=$(date +%F_%H%M%S)
OUT="$OUTDIR/metrics_$NOW.txt"

{
  echo "=== System Metrics: $NOW ==="
  echo "--- Uptime ---"
  uptime
  echo "--- CPU ---"
  mpstat 2>/dev/null || top -b -n1 | head -n 5
  echo "--- Memory ---"
  free -m
  echo "--- Disk ---"
  df -h
  echo "--- Network ---"
  ip -s link
} > "$OUT"

echo "Metrics snapshot saved to $OUT"
