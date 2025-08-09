#!/bin/bash
# Updates packages on multiple servers via SSH

SERVERS="server1 server2 server3"
for srv in $SERVERS; do
  ssh "$srv" 'sudo apt update && sudo apt -y upgrade'
done
