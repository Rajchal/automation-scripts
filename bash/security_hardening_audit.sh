#!/bin/bash

echo "=== Security Hardening Quick Audit ==="

echo -e "\n1. Password Policy:"
grep -E '^PASS_MAX_DAYS|^PASS_MIN_DAYS|^PASS_MIN_LEN' /etc/login.defs

echo -e "\n2. SSH Root Login Disabled:"
grep "^PermitRootLogin" /etc/ssh/sshd_config

echo -e "\n3. SSH Password Authentication Disabled:"
grep "^PasswordAuthentication" /etc/ssh/sshd_config

echo -e "\n4. Firewall Status (ufw):"
ufw status verbose

echo -e "\n5. World-Writable Files:"
find / -xdev -type f -perm -0002 -ls 2>/dev/null | head

echo -e "\n6. Sudoers with NOPASSWD:"
grep NOPASSWD /etc/sudoers /etc/sudoers.d/* 2>/dev/null

echo -e "\n7. Running as root processes:"
ps -U root -u root u | wc -l
