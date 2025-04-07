#!/bin/bash
echo "Starting deployment..."
git pull origin main
docker build -t myapp:latest .
docker stop myapp || true
docker rm myapp || true
docker run -d --name myapp -p 80:80 myapp:latest
echo "Deployment completed."

