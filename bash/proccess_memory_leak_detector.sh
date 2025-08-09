#!/bin/bash
# Detects processes using more than 80% of system RAM

THRESHOLD=80
ps -eo pid,comm,%mem --sort=-%mem | awk -v t=$THRESHOLD 'NR>1 && $3>t {print "High memory use:", $0}'
