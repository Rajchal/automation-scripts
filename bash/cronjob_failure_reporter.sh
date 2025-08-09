#!/bin/bash
# Scans /var/log/syslog for cron job failures in the last 24 hours

grep CRON /var/log/syslog | grep -i "error\|fail" | grep "$(date +"%b %_d")"
