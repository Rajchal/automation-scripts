#!/bin/bash

# Bash script to check monthly AWS cost using AWS CLI
set -e

echo "Checking AWS cost..."

# Set AWS CLI profile
read -p "Enter the AWS CLI profile to use: " AWS_PROFILE
export AWS_PROFILE

# Get current month and year
YEAR=$(date +%Y)
MONTH=$(date +%m)

# Fetch cost details using AWS CLI
aws ce get-cost-and-usage \
  --time-period Start="$YEAR-$MONTH-01",End="$(date -d 'next month' +%Y-%m-01)" \
  --granularity MONTHLY \
  --metrics "BlendedCost" \
  --output table

echo "AWS cost check complete!"
