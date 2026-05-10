#!/usr/bin/env python3
"""
JSON Log Parser
---------------
A versatile CLI tool for filtering and extracting specific fields from
JSON formatted log files.

Usage:
    # Filter logs where level is ERROR
    python3 json-log-parser.py app.log --filter level ERROR
    
    # Extract specific fields (timestamp and message)
    python3 json-log-parser.py app.log --extract timestamp message
"""

import json
import argparse
import sys

def parse_logs(file_path, filter_key=None, filter_value=None, extract_keys=None):
    try:
        with open(file_path, 'r') as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                    
                try:
                    log_entry = json.loads(line)
                except json.JSONDecodeError:
                    print(f"Warning: Skipping invalid JSON on line {line_num}", file=sys.stderr)
                    continue
                    
                # Apply filter
                if filter_key and filter_value:
                    val = log_entry.get(filter_key)
                    if str(val) != filter_value:
                        continue
                        
                # Extract fields
                if extract_keys:
                    extracted = {k: log_entry.get(k) for k in extract_keys}
                    print(json.dumps(extracted))
                else:
                    print(json.dumps(log_entry))
                    
    except FileNotFoundError:
        print(f"Error: File '{file_path}' not found.", file=sys.stderr)
        sys.exit(1)
    except IOError as e:
        print(f"Error reading file: {e}", file=sys.stderr)
        sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Parse and filter JSON log files")
    parser.add_argument("file", help="Path to the JSON log file")
    parser.add_argument("--filter", nargs=2, metavar=('KEY', 'VALUE'),
                        help="Filter logs where KEY equals VALUE")
    parser.add_argument("--extract", nargs='+', metavar='KEY',
                        help="Extract specific keys from the log entries")
                        
    args = parser.parse_args()
    
    filter_key, filter_val = None, None
    if args.filter:
        filter_key, filter_val = args.filter
        
    parse_logs(args.file, filter_key, filter_val, args.extract)

if __name__ == "__main__":
    main()
