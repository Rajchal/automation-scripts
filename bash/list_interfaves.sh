#!/bin/bash
ip -o -4 addr show | awk '{print $2, $4}'
