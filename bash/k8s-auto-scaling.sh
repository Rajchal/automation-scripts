#!/bin/bash

# Bash script to autoscale Kubernetes deployments
set -e

echo "Starting Kubernetes autoscaling..."

# Input deployment details
read -p "Enter namespace: " NAMESPACE
read -p "Enter deployment name: " DEPLOYMENT
read -p "Enter minimum replicas: " MIN_REPLICAS
read -p "Enter maximum replicas: " MAX_REPLICAS
read -p "Enter CPU utilization percentage: " CPU_UTIL

# Apply autoscaling
kubectl autoscale deployment "$DEPLOYMENT" -n "$NAMESPACE" \
  --min="$MIN_REPLICAS" --max="$MAX_REPLICAS" --cpu-percent="$CPU_UTIL"

echo "Autoscaling applied to deployment: $DEPLOYMENT"
