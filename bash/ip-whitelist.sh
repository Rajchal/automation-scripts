#!/bin/bash
read -p "Enter IP to whitelist: " IP
iptables -A INPUT -s "$IP" -j ACCEPT
echo "IP $IP whitelisted."
