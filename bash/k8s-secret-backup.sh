#!/bin/bash

# Bash script to back up all Kubernetes secrets in a namespace
set -e

echo "Backing up Kubernetes secrets..."

# Input namespace
read -p "Enter the namespace: " NAMESPACE
BACKUP_DIR="k8s_secrets_backup"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Export all secrets
kubectl get secrets -n "$NAMESPACE" -o yaml > "$BACKUP_DIR/secrets_$NAMESPACE.yaml"

echo "Secrets backed up to $BACKUP_DIR/secrets_$NAMESPACE.yaml."
