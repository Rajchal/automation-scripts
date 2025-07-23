#!/bin/bash

echo "=== Docker Container Resource Usage ==="
docker stats --no-stream

echo -e "\n=== Containers Exceeding Memory Limit (500MB) ==="
docker stats --no-stream --format "{{.Container}} {{.Name}} {{.MemUsage}}" | \
awk '{split($3,mem,"/"); split(mem[1],val,"M"); if (val[1] + 0 > 500) print $2, mem[1]}'

echo -e "\n=== Restarting Stopped Containers ==="
for id in $(docker ps -aq -f "status=exited"); do
    name=$(docker inspect --format='{{.Name}}' "$id" | cut -c2-)
    echo "Restarting $name ($id)..."
    docker restart "$id"
done

echo "Docker audit and restart complete."
