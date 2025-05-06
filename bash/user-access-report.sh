#!/bin/bash

# Bash script to generate a report of user access to a Linux server
set -e

echo "Generating user access report..."

# Output file
OUTPUT_FILE="user_access_report.txt"

# List all users
echo "User Access Report - $(date)" > "$OUTPUT_FILE"
echo "---------------------------------" >> "$OUTPUT_FILE"
getent passwd | while IFS=: read -r USER _ UID _ _ _ HOME _; do
  if [[ "$UID" -ge 1000 ]]; then
    echo "User: $USER" >> "$OUTPUT_FILE"
    echo "Home Directory: $HOME" >> "$OUTPUT_FILE"
    echo "Last Login: $(lastlog -u "$USER" | tail -1)" >> "$OUTPUT_FILE"
    echo "---------------------------------" >> "$OUTPUT_FILE"
  fi
done

echo "User access report saved to $OUTPUT_FILE."
