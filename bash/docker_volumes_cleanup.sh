#!/bin/bash
# Removes all dangling Docker volumes

docker volume prune -f
