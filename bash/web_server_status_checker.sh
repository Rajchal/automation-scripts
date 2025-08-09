#!/bin/bash
# Checks if web servers respond to HTTP and HTTPS

SITES=("https://example.com" "http://example.org")
for s in "${SITES[@]}"; do
  curl -Is "$s" | head -n 1
done
