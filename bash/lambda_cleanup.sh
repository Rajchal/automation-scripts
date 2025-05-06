#!/bin/bash

# Bash script to delete old AWS Lambda function versions
set -e

echo "Cleaning up old Lambda function versions..."

# Input Lambda function name
read -p "Enter the name of the Lambda function: " FUNCTION_NAME

# Fetch all versions of the Lambda function
VERSIONS=$(aws lambda list-versions-by-function --function-name "$FUNCTION_NAME" \
  --query "Versions[?Version!='\$LATEST'].Version" --output text)

# Delete all old versions
for VERSION in $VERSIONS; do
  echo "Deleting version: $VERSION"
  aws lambda delete-function --function-name "$FUNCTION_NAME" --qualifier "$VERSION"
done

echo "Lambda function cleanup complete!"
