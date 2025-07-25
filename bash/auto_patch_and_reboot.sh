#!/bin/bash

LOG="/var/log/auto_patch_and_reboot.log"
echo "=== System Patch and Reboot: $(date) ===" | tee -a "$LOG"

echo "Updating package lists..." | tee -a "$LOG"
apt update | tee -a "$LOG"

echo "Upgrading packages..." | tee -a "$LOG"
apt -y upgrade | tee -a "$LOG"

echo "Cleaning up..." | tee -a "$LOG"
apt -y autoremove | tee -a "$LOG"
apt -y autoclean | tee -a "$LOG"

echo "Checking for reboot required..." | tee -a "$LOG"
if [ -f /var/run/reboot-required ]; then
    echo "Reboot required. Rebooting now..." | tee -a "$LOG"
    shutdown -r now
else
    echo "No reboot required." | tee -a "$LOG"
fi
