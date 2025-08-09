#!/bin/bash
# Reports CPU temperature on systems with sensors

sensors | grep -i 'cpu'
