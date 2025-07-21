#!/bin/bash
grep "Failed password" /var/log/auth.log | tail -n 10
