#!/bin/bash

SERVICES=("nginx" "docker" "sshd" "mysql")
DASH="/var/www/html/service_status.html"

{
  echo "<html><head><title>Service Status</title></head><body>"
  echo "<h1>Service Status as of $(date)</h1><ul>"
  for svc in "${SERVICES[@]}"; do
    systemctl is-active --quiet "$svc" && STATUS="✅ RUNNING" || STATUS="❌ DOWN"
    echo "<li><b>$svc:</b> $STATUS</li>"
  done
  echo "</ul></body></html>"
} > "$DASH"

echo "Dashboard generated at $DASH"
