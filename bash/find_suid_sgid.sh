#!/bin/bash
echo "SUID files:"
find / -perm -4000 -type f 2>/dev/null
echo "SGID files:"
find / -perm -2000 -type f 2>/dev/null
