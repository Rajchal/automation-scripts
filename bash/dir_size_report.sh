#!/bin/bash

TARGET=${1:-/}
REPORT="/tmp/dir_size_report_$(date +%F).txt"

du -h --max-depth=2 "$TARGET" 2>/dev/null | sort -hr | head -n 10 > "$REPORT"
echo "Top 10 largest directories under $TARGET:"
cat "$REPORT"
