#!/bin/bash
boot_time=$(who -b | awk '{print $3" "$4}')
find / -type f -newermt "$boot_time" 2>/dev/null
