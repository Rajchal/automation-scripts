#!/bin/bash

# Bash script to analyze resource usage of Kubernetes pods
set -e

echo "Analyzing Kubernetes pod resource usage..."

# Get namespaces
NAMESPACES=$(kubectl get namespaces --no-headers -o custom-columns=":metadata.name")

for NAMESPACE in $NAMESPACES; do
  echo "Namespace: $NAMESPACE"
  kubectl top pod -n "$NAMESPACE"
  echo "----------------------------------"
done
