#!/bin/bash

# Bash script to check Terraform state for specific resources
set -e

echo "Checking Terraform state..."

# Input Terraform state file location
read -p "Enter the path to the Terraform state file: " STATE_FILE
read -p "Enter the resource name to search for: " RESOURCE_NAME

# Validate inputs
if [[ ! -f "$STATE_FILE" ]]; then
  echo "Terraform state file $STATE_FILE does not exist."
  exit 1
fi

# Search for the resource in the state file
grep -A 5 "$RESOURCE_NAME" "$STATE_FILE"

echo "Terraform state check complete!"
