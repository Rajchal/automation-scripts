#!/bin/bash

NAMESPACES=$(kubectl get ns --no-headers | awk '{print $1}')

for ns in $NAMESPACES; do
  kubectl get pods -n "$ns" --field-selector=status.phase!=Running --no-headers | grep CrashLoopBackOff | while read line; do
    POD=$(echo $line | awk '{print $1}')
    echo "Restarting pod $POD in namespace $ns"
    kubectl delete pod "$POD" -n "$ns"
  done
done
