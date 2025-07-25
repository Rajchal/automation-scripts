#!/bin/bash

TARGET_DIR="/var/www/html"
OWNER="www-data"
GROUP="www-data"
DIR_PERMS=755
FILE_PERMS=644

echo "Fixing permissions in $TARGET_DIR..."

find "$TARGET_DIR" -type d -exec chmod $DIR_PERMS {} +
find "$TARGET_DIR" -type f -exec chmod $FILE_PERMS {} +
chown -R $OWNER:$GROUP "$TARGET_DIR"

echo "Permissions fixed."
