#!/bin/bash

echo "=== Kubernetes Namespace Usage ==="
for ns in $(kubectl get ns --no-headers | awk '{print $1}'); do
  echo "--- $ns ---"
  kubectl get pods -n "$ns" --no-headers | wc -l | xargs echo "Pods:"
  kubectl get svc -n "$ns" --no-headers | wc -l | xargs echo "Services:"
  kubectl get deploy -n "$ns" --no-headers | wc -l | xargs echo "Deployments:"
done
