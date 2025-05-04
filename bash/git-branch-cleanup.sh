#!/bin/bash

# Bash script to delete merged branches
set -e

echo "Cleaning up merged branches..."

# Fetch latest changes
git fetch --all

# Delete all merged branches except main/master
git branch --merged | grep -vE "(^\*|main|master)" | while read -r BRANCH; do
  echo "Deleting branch: $BRANCH"
  git branch -d "$BRANCH"
done

echo "Branch cleanup complete!"
