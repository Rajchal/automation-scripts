#!/bin/bash
for svc in sshd nginx docker; do
    systemctl is-active --quiet $svc && echo "$svc is running" || echo "$svc is NOT running"
done
