#!/bin/bash

# Reports uptime of all processes and highlights any running longer than 7 days
ps -eo pid,etime,comm --sort=-etime | awk 'NR==1{print;next} {split($2,a,"-"); if(length(a)>1 && a[1]>7) print "Long running:",$0; else print $0}'
