#!/bin/bash

WEBROOT="/var/www/html"
OWNER="www-data"
GROUP="www-data"

echo "Fixing directory permissions..."
find "$WEBROOT" -type d -exec chmod 755 {} +
echo "Fixing file permissions..."
find "$WEBROOT" -type f -exec chmod 644 {} +
echo "Setting ownership..."
chown -R "$OWNER:$GROUP" "$WEBROOT"
echo "Permissions fixed for $WEBROOT"
