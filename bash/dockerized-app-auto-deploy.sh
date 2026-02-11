#!/bin/bash

set -e

APP_DIR="/var/www/myapp"
CONTAINER_NAME="myapp_container"

echo "🚀 Starting deployment..."

cd $APP_DIR

echo "📥 Pulling latest code..."
git pull origin main

echo "🐳 Rebuilding Docker image..."
docker build -t myapp:latest .

echo "🛑 Stopping old container..."
docker stop $CONTAINER_NAME || true
docker rm $CONTAINER_NAME || true

echo "▶ Starting new container..."
docker run -d \
  --name $CONTAINER_NAME \
  -p 80:3000 \
  --restart unless-stopped \
  myapp:latest

echo "✅ Deployment successful."
