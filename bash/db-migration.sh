#!/bin/bash

# Bash script to automate database migration
set -e

echo "Starting database migration..."

# Input database details
read -p "Enter source database connection string: " SOURCE_DB
read -p "Enter target database connection string: " TARGET_DB

# Migrate data
pg_dump "$SOURCE_DB" | psql "$TARGET_DB"

echo "Database migration complete!"
