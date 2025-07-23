#!/bin/bash

echo "=== Hostname ==="
hostname

echo -e "\n=== Uptime ==="
uptime

echo -e "\n=== Disk Usage (over 80%) ==="
df -h | awk 'NR==1 || int($5) > 80'

echo -e "\n=== Memory Usage ==="
free -h

echo -e "\n=== Top 5 Memory Consuming Processes ==="
ps aux --sort=-%mem | head -n 6

echo -e "\n=== Top 5 CPU Consuming Processes ==="
ps aux --sort=-%cpu | head -n 6

echo -e "\n=== Failed Systemd Services ==="
systemctl --failed

echo -e "\n=== Zombie Processes ==="
ps -eo pid,ppid,state,comm | awk '$3=="Z" {print $0}'

echo -e "\n=== Listening Network Ports ==="
ss -tulnp

echo -e "\n=== Recent Authentication Failures ==="
grep "Failed password" /var/log/auth.log | tail -n 10

echo -e "\n=== World-Writable Files ==="
find / -xdev -type f -perm -0002 -ls 2>/dev/null | head -n 10

echo -e "\n=== SUID/SGID Files ==="
find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | head -n 10

echo -e "\n=== Users with UID 0 ==="
awk -F: '$3 == 0 {print $1}' /etc/passwd

echo -e "\n=== Custom Checks Complete ==="
