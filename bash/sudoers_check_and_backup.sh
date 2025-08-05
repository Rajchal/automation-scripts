#!/bin/bash

BACKUP="/etc/sudoers.bak.$(date +%F)"
visudo -c
if [ $? -eq 0 ]; then
  cp /etc/sudoers "$BACKUP"
  echo "Sudoers syntax OK. Backup saved to $BACKUP"
else
  echo "Sudoers syntax error! Please fix before backup."
fi
