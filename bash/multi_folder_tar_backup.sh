#!/bin/bash
# Creates tar.gz backups of multiple folders

FOLDERS="/etc /var/www /home"
DEST="/backups/$(date +%F)"
mkdir -p "$DEST"
for f in $FOLDERS; do
  tar czf "$DEST/$(basename $f).tar.gz" "$f"
done
