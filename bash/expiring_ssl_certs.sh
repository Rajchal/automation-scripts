#!/bin/bash
find /etc/ssl -type f -name "*.crt" | while read cert; do
    end_date=$(openssl x509 -noout -enddate -in "$cert" 2>/dev/null | cut -d= -f2)
    if [[ $end_date ]]; then
        echo "$cert expires on $end_date"
    fi
done
