#!/bin/bash

echo "Checking Nginx configuration syntax..."
if nginx -t; then
  echo "Syntax OK. Reloading Nginx..."
  systemctl reload nginx
  echo "Nginx reloaded."
else
  echo "Nginx config error. Not reloading."
fi
