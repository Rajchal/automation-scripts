#!/bin/bash

# Bash script to scan Docker images for vulnerabilities using Trivy
set -e

echo "Starting container vulnerability scan..."

# Input the Docker image to scan
read -p "Enter the Docker image name (e.g., nginx:latest): " IMAGE_NAME

# Validate input
if [[ -z "$IMAGE_NAME" ]]; then
  echo "Image name is required."
  exit 1
fi

# Check if Trivy is installed
if ! command -v trivy &> /dev/null; then
  echo "Trivy is not installed. Please install Trivy and try again."
  exit 1
fi

# Run Trivy scan
trivy image "$IMAGE_NAME"

echo "Vulnerability scan complete!"
