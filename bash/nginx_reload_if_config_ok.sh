#!/bin/bash
# Reloads nginx only if config test passes

nginx -t && systemctl reload nginx
