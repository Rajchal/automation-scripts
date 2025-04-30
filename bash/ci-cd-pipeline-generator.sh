#!/bin/bash

# Bash script to auto-generate a GitHub Actions CI/CD pipeline YAML file
set -e

echo "Generating CI/CD pipeline..."

# Create .github/workflows directory if it doesn't exist
mkdir -p .github/workflows

# Generate a sample CI/CD pipeline file
cat <<EOL > .github/workflows/ci_cd_pipeline.yml
name: CI/CD Pipeline

on:
  push:
    branches:
      - main

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Set up Node.js
        uses: actions/setup-node@v3
        with:
          node-version: 16

      - name: Install dependencies
        run: npm install

      - name: Run tests
        run: npm test

      - name: Deploy to production
        if: github.ref == 'refs/heads/main'
        run: echo "Deploying to production..."
EOL

echo "CI/CD pipeline generated at .github/workflows/ci_cd_pipeline.yml"
