#!/bin/bash
SRC_DIR="/etc"
DEST_DIR="/backup"
DATE=$(date +%F)
tar czvf $DEST_DIR/etc-backup-$DATE.tar.gz $SRC_DIR
