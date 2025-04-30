#!/bin/bash

# Bash script to dynamically set up an environment (dev, staging, prod)
set -e

echo "Starting environment setup..."

# Input environment name
read -p "Enter the environment name (dev/staging/prod): " ENV

# Validate input
if [[ "$ENV" != "dev" && "$ENV" != "staging" && "$ENV" != "prod" ]]; then
  echo "Invalid environment. Choose 'dev', 'staging', or 'prod'."
  exit 1
fi

# Install dependencies based on the environment
if [[ "$ENV" == "dev" ]]; then
  echo "Installing development dependencies..."
  sudo apt-get update && sudo apt-get install -y git curl
elif [[ "$ENV" == "staging" ]]; then
  echo "Setting up staging environment..."
  sudo apt-get update && sudo apt-get install -y nginx
elif [[ "$ENV" == "prod" ]]; then
  echo "Setting up production environment..."
  sudo apt-get update && sudo apt-get install -y docker.io
fi

echo "Setting up environment variables for $ENV..."
export ENVIRONMENT=$ENV
export APP_PORT=8080

echo "Environment $ENV setup complete!"
