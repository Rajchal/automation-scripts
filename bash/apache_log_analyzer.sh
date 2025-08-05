#!/bin/bash

LOG="/var/log/apache2/access.log"
OUT="/tmp/apache_report_$(date +%F).txt"

echo "=== Top 10 IPs ===" > "$OUT"
awk '{print $1}' "$LOG" | sort | uniq -c | sort -nr | head -10 >> "$OUT"
echo -e "\n=== Top 10 Requested URLs ===" >> "$OUT"
awk '{print $7}' "$LOG" | sort | uniq -c | sort -nr | head -10 >> "$OUT"
echo "Report saved to $OUT"
