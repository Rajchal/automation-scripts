#!/bin/bash

# Checks if swap exists, creates a 2G swap file if not, enables it, and adds to fstab
if free | grep -q Swap.*0; then
  echo "No swap detected. Creating 2G swap file..."
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "Swap created and enabled."
else
  echo "Swap already exists."
fi
