#!/bin/bash

MOUNTS=$(grep nfs /etc/fstab | awk '{print $2}')

for mount in $MOUNTS; do
  if ! mount | grep -q "on $mount "; then
    echo "NFS mount $mount is not mounted, attempting to mount..."
    mount "$mount"
    if mount | grep -q "on $mount "; then
      echo "Successfully mounted $mount"
    else
      echo "Failed to mount $mount"
    fi
  else
    echo "NFS mount $mount is OK"
  fi
done
