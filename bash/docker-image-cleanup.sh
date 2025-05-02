#!/bin/bash

# Bash script to clean up unused Docker images
set -e

echo "Cleaning up unused Docker images..."

# Remove dangling images
docker image prune -f

# Remove images older than a certain number of days
read -p "Enter the number of days to keep images: " DAYS
if [[ -z "$DAYS" ]]; then
  DAYS=30
fi

docker images --filter "dangling=false" --format "{{.Repository}}:{{.Tag}} {{.CreatedSince}}" | while read -r IMAGE CREATED; do
  if [[ "$CREATED" == *"weeks"* || "$CREATED" == *"months"* || "$CREATED" == *"years"* ]]; then
    echo "Removing image: $IMAGE"
    docker rmi "$IMAGE"
  fi
done

echo "Docker image cleanup complete!"
