#!/bin/bash
host=$1
port=${2:-443}
echo | openssl s_client -servername $host -connect $host:$port 2>/dev/null | openssl x509 -noout -dates
