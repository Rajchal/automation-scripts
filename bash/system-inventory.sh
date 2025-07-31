#!/bin/bash

OUT="system_inventory_$(date +%F).txt"

{
  echo "=== System Inventory Report: $(date) ==="
  echo "--- Hostname ---"
  hostname
  echo "--- OS ---"
  lsb_release -a 2>/dev/null || cat /etc/*release
  echo "--- Kernel ---"
  uname -a
  echo "--- CPU ---"
  lscpu
  echo "--- Memory ---"
  free -h
  echo "--- Storage ---"
  lsblk
  echo "--- Network ---"
  ip addr
  echo "--- PCI Devices ---"
  lspci
  echo "--- USB Devices ---"
  lsusb
} > "$OUT"

echo "Inventory saved to $OUT"
