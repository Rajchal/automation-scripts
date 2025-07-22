#!/bin/bash
if [ -z "$1" ]; then
    echo "Usage: $0 <pid>"
    exit 1
fi
lsof -p "$1"
