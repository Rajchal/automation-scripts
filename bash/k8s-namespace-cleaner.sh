#!/bin/bash

# Bash script to clean up unused Kubernetes namespaces
set -e

echo "Cleaning up unused Kubernetes namespaces..."

# Get a list of namespaces
NAMESPACES=$(kubectl get namespaces --no-headers -o custom-columns=":metadata.name")

for NAMESPACE in $NAMESPACES; do
  if [[ "$NAMESPACE" != "default" && "$NAMESPACE" != "kube-system" && "$NAMESPACE" != "kube-public" ]]; then
    echo "Deleting namespace: $NAMESPACE"
    kubectl delete namespace "$NAMESPACE"
  fi
done

echo "Namespace cleanup complete!"
