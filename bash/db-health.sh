#!/bin/bash

# Bash script to monitor database health
set -e

echo "Starting database health check..."

# Database connection details
DB_HOST="127.0.0.1"
DB_USER="root"
DB_PASSWORD="password"

# Check MySQL is running
if ! systemctl is-active --quiet mysql; then
  echo "MySQL service is down! Restarting..."
  systemctl restart mysql
  echo "MySQL restarted successfully!"
fi

# Check database connectivity
mysqladmin -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" ping > /dev/null 2>&1
if [[ $? -ne 0 ]]; then
  echo "Database is not responding! Check connection settings."
else
  echo "Database is healthy and responding!"
fi
