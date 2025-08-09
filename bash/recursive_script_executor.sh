#!/bin/bash
# Recursively executes all scripts in a directory

DIR=${1:-/opt/scripts}
find "$DIR" -type f -executable -name "*.sh" -exec {} \;
