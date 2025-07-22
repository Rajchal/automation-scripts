#!/bin/bash
grep "install " /var/log/dpkg.log* | grep "$(date --date='7 days ago' +%Y-%m-%d)" -A1000
