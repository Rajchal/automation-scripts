#!/bin/bash

# Prunes unused Docker images older than 7 days
THRESHOLD_DAYS=7
docker images --format '{{.Repository}}:{{.Tag}} {{.CreatedSince}} {{.ID}}' | while read line; do
  repo_tag=$(echo "$line" | awk '{print $1}')
  created=$(echo "$line" | awk '{print $2}')
  id=$(echo "$line" | awk '{print $3}')
  if [[ $created == *"week"* || $created == *"month"* || $created == *"year"* ]]; then
    echo "Removing old image $repo_tag ($id)"
    docker rmi "$id"
  fi
done
