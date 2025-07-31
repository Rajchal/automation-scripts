#!/bin/bash

START_DATE=$(date -d '30 days ago' +%Y-%m-%d)
END_DATE=$(date +%Y-%m-%d)

aws ce get-cost-and-usage \
  --time-period Start=$START_DATE,End=$END_DATE \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --output table
