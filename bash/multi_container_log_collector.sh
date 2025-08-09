#!/bin/bash
# Collects logs from all running Docker containers

for cid in $(docker ps -q); do
  docker logs "$cid" > "docker_${cid}_$(date +%F).log"
done
