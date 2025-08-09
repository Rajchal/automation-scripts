#!/bin/bash
# Finds and removes orphaned packages (Debian/Ubuntu)

apt autoremove --dry-run
