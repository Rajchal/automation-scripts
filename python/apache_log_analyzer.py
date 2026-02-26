#!/usr/bin/env python3
"""apache_log_analyzer.py

Simple Apache access log analyzer: top IPs, top requested paths, and status counts.

Usage:
  python apache_log_analyzer.py /var/log/apache2/access.log
  zcat access.log.gz | python apache_log_analyzer.py -
"""
from __future__ import annotations
import argparse
import collections
import gzip
import re
import sys
from typing import Iterable

LOG_RE = re.compile(r'(?P<ip>\S+) \S+ \S+ \[[^\]]+\] "(?P<req>.*?)" (?P<status>\d{3}) (?P<size>\S+)')


def open_stream(path: str):
    if path == "-":
        return sys.stdin
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, "r", encoding="utf-8", errors="replace")


def parse_lines(lines: Iterable[str]):
    ips = collections.Counter()
    paths = collections.Counter()
    statuses = collections.Counter()
    methods = collections.Counter()

    for line in lines:
        m = LOG_RE.search(line)
        if not m:
            continue
        ip = m.group("ip")
        req = m.group("req")
        status = m.group("status")
        ips[ip] += 1
        statuses[status] += 1
        # req is like: GET /path HTTP/1.1
        parts = req.split()
        if len(parts) >= 2:
            methods[parts[0]] += 1
            paths[parts[1]] += 1

    return ips, paths, statuses, methods


def print_top(counter: collections.Counter, title: str, n: int = 10):
    print(f"{title} (top {n}):")
    for item, cnt in counter.most_common(n):
        print(f"  {item}	{cnt}")
    print()


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze Apache access logs")
    parser.add_argument("paths", nargs="*", default=["-"], help="Log files to analyze (use - for stdin)")
    parser.add_argument("-n", type=int, default=10, help="Top N items to show")
    args = parser.parse_args()

    agg_ips = collections.Counter()
    agg_paths = collections.Counter()
    agg_status = collections.Counter()
    agg_methods = collections.Counter()

    for p in args.paths:
        try:
            with open_stream(p) as fh:
                ips, paths, statuses, methods = parse_lines(fh)
                agg_ips.update(ips)
                agg_paths.update(paths)
                agg_status.update(statuses)
                agg_methods.update(methods)
        except FileNotFoundError:
            print(f"File not found: {p}", file=sys.stderr)
        except Exception as e:
            print(f"Error reading {p}: {e}", file=sys.stderr)

    print_top(agg_ips, "Top client IPs", args.n)
    print_top(agg_paths, "Top requested paths", args.n)
    print_top(agg_methods, "Request methods", args.n)
    print_top(agg_status, "Status codes", args.n)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
