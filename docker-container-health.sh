#!/bin/bash
for container in $(docker ps --format "{{.Names}}"); do
    STATUS=$(docker inspect --format '{{.State.Health.Status}}' $container)
    echo "Container: $container - Status: $STATUS"
done
