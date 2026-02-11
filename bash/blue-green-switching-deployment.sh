#!/bin/bash

set -euo pipefail

APP_NAME="myapp"
IMAGE_NAME="myapp:latest"
NGINX_CONF="/etc/nginx/conf.d/myapp.conf"
LOCK_FILE="/tmp/deploy.lock"
HEALTH_URL="http://localhost:8080/health"

BLUE_PORT=8081
GREEN_PORT=8082

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Prevent concurrent deploy
if [ -f "$LOCK_FILE" ]; then
  log "Another deployment is running."
  exit 1
fi

touch $LOCK_FILE
trap "rm -f $LOCK_FILE" EXIT

log "Pulling latest image..."
docker pull $IMAGE_NAME

# Determine active environment
if docker ps | grep -q "${APP_NAME}_blue"; then
  ACTIVE="blue"
  INACTIVE="green"
  NEW_PORT=$GREEN_PORT
else
  ACTIVE="green"
  INACTIVE="blue"
  NEW_PORT=$BLUE_PORT
fi

log "Active environment: $ACTIVE"
log "Deploying to: $INACTIVE"

# Stop old inactive if exists
docker rm -f ${APP_NAME}_${INACTIVE} 2>/dev/null || true

# Start new container
docker run -d \
  --name ${APP_NAME}_${INACTIVE} \
  -p $NEW_PORT:3000 \
  --restart unless-stopped \
  $IMAGE_NAME

log "Waiting for health check..."

sleep 5

# Health Check Loop
for i in {1..10}; do
  if curl -sf http://localhost:$NEW_PORT/health > /dev/null; then
    log "Health check passed."
    break
  fi
  log "Health check failed. Retrying..."
  sleep 3
done

# Final check
if ! curl -sf http://localhost:$NEW_PORT/health > /dev/null; then
  log "Deployment failed. Rolling back."
  docker rm -f ${APP_NAME}_${INACTIVE}
  exit 1
fi

log "Switching NGINX to $INACTIVE..."

cat > $NGINX_CONF <<EOF
server {
    listen 80;

    location / {
        proxy_pass http://localhost:$NEW_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

nginx -s reload

log "Stopping old container..."
docker rm -f ${APP_NAME}_${ACTIVE}

log "Deployment successful."
