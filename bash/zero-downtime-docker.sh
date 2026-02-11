#!/bin/bash

NEW_IMAGE="myapp:new"

docker pull $NEW_IMAGE

docker run -d --name myapp_new -p 8081:3000 $NEW_IMAGE

sleep 10

docker stop myapp_old
docker rm myapp_old

docker rename myapp_new myapp_old

echo "✅ Rolling update complete."
