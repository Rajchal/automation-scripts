#!/bin/bash
ps -eo pid,ppid,state,comm | awk '$3=="Z" {print "Zombie PID:", $1, "PPID:", $2, "Command:", $4}'
