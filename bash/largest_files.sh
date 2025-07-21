#!/bin/bash
du -ah "$1" 2>/dev/null | sort -rh | head -n 10
