#!/bin/bash

# Computes SHA256 hashes of all files under a directory and saves to a report
TARGET=${1:-/etc}
REPORT="/tmp/file_hashes_$(date +%F).txt"

find "$TARGET" -type f -exec sha256sum {} \; > "$REPORT"
echo "SHA256 hashes saved to $REPORT"
