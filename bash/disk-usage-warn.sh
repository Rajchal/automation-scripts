#!/bin/bash
df -h | awk 'NR>1 {if (int($5) > 80) print "Warning:", $6, "is", $5, "full"}'
