#!/bin/bash

CSV="users.csv"

if [ ! -f "$CSV" ]; then
  echo "CSV file not found!"
  exit 1
fi

while IFS=, read -r user pass; do
  id "$user" &>/dev/null || useradd -m "$user"
  echo "$user:$pass" | chpasswd
  echo "Created user $user"
done < "$CSV"
