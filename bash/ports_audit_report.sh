#!/bin/bash

REPORT="/var/log/ports_audit_$(date +%F).txt"
echo "Open ports on $(hostname) at $(date):" > "$REPORT"
ss -tulnp | tee -a "$REPORT"
mail -s "Open Ports Report for $(hostname)" admin@example.com < "$REPORT"
