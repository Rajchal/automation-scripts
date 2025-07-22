#!/bin/bash
find / -xdev \( -nouser -o -nogroup \) -ls 2>/dev/null
