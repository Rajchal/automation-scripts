#!/bin/bash

echo "=== User Account Audit ==="
echo "Users with UID 0 (root privileges):"
awk -F: '$3 == 0 {print $1}' /etc/passwd

echo -e "\nUsers with empty passwords:"
awk -F: '($2 == "" ) {print $1}' /etc/shadow

echo -e "\nLocked user accounts:"
awk -F: '($2 ~ /!|*/) {print $1}' /etc/shadow

echo -e "\nUsers who haven't logged in within 90 days:"
lastlog -b 90

echo -e "\nNon-expiring passwords:"
chage -l $(cut -d: -f1 /etc/passwd) 2>/dev/null | grep 'never'
