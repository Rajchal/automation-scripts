#!/bin/bash

# Git pre-push hook to run linters before pushing
set -e

echo "Running pre-push checks..."

# Run linter
if ! npm run lint; then
  echo "Linting failed. Please fix the issues before pushing."
  exit 1
fi

echo "All checks passed! Proceeding with push."
