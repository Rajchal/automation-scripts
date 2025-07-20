#!/bin/bash
find / -xdev -type f -perm -0002 -ls 2>/dev/null
