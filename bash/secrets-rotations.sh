#!/bin/bash

# Bash script to rotate secrets automatically
set -e

VAULT_API="https://vault.myorg.com"
SECRET_PATH="myapp/secrets"
NEW_SECRET=$(openssl rand -base64 32)

echo "Rotating secrets..."

# Update the secret in Vault
curl -X POST -H "Content-Type: application/json" \
  -d "{\"new_secret\": \"$NEW_SECRET\"}" \
  $VAULT_API/v1/$SECRET_PATH

echo "Secrets rotated successfully!"
