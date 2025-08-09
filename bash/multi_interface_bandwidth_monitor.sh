#!/bin/bash

# Monitors bandwidth usage for all network interfaces over a 10-second interval
INTERFACES=$(ls /sys/class/net | grep -v lo)
echo "Interface RX(KB/s)  TX(KB/s)"
for IFACE in $INTERFACES; do
  RX1=$(cat /sys/class/net/$IFACE/statistics/rx_bytes)
  TX1=$(cat /sys/class/net/$IFACE/statistics/tx_bytes)
  sleep 10
  RX2=$(cat /sys/class/net/$IFACE/statistics/rx_bytes)
  TX2=$(cat /sys/class/net/$IFACE/statistics/tx_bytes)
  RX_RATE=$((($RX2 - $RX1)/10240))
  TX_RATE=$((($TX2 - $TX1)/10240))
  echo "$IFACE   $RX_RATE       $TX_RATE"
done
