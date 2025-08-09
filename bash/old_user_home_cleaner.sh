#!/bin/bash
# Finds and removes home directories not accessed in over 90 days

find /home -mindepth 1 -maxdepth 1 -type d -atime +90 -exec rm -rf {} \;
