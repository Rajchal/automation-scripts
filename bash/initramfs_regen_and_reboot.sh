#!/bin/bash
# Regenerates initramfs and reboots (for kernel/init issues)

update-initramfs -u -k all && reboot
