#!/bin/bash

echo "=== Kubernetes Nodes ==="
kubectl get nodes -o wide

echo -e "\n=== All Pods (all namespaces) ==="
kubectl get pods --all-namespaces -o wide

echo -e "\n=== Pods in CrashLoopBackOff ==="
kubectl get pods --all-namespaces | grep CrashLoopBackOff

echo -e "\n=== Services (all namespaces) ==="
kubectl get svc --all-namespaces

echo -e "\n=== Deployments (all namespaces) ==="
kubectl get deploy --all-namespaces

echo -e "\n=== Cluster Info ==="
kubectl cluster-info

echo -e "\n=== Current Context ==="
kubectl config current-context
