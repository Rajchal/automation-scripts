#!/bin/bash

# Finds all broken symbolic links in /home and reports them
find /home -xtype l > /tmp/broken_symlinks_$(date +%F).txt
echo "Broken symlinks reported in /tmp/broken_symlinks_$(date +%F).txt"
