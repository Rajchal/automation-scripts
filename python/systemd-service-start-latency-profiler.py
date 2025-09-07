#!/usr/bin/env python3
"""
Systemd Service Start Latency Profiler

Parses journalctl to compute service start latency statistics over recent boots.

Latency model:
  (time service reached 'active (running)' OR 'failed') - (time start job began)

We approximate using journal messages:
  - Job start:   "Starting <UnitDesc>..." or "Started" lines timestamp (fallback to first log line after previous stop)
  - Job success: "Started <UnitDesc>" or state change to active in systemctl show
  - Job failure: "Failed to start <UnitDesc>" (counts with failure flag)

Outputs per service:
  Service  Starts  Success  Fail  p50  p95  Max  MeanSeconds  LastStartAge

Usage:
  python systemd-service-start-latency-profiler.py --services nginx.service,sshd.service --since 2d
  python systemd-service-start-latency-profiler.py --pattern 'nginx|haproxy' --json

Options:
  --services <list>  Comma list of explicit service unit names
  --pattern <regex>  Regex to match service names (union with --services)
  --since <timespec> Passed to journalctl (default '1d')
  --limit <N>        Max journal lines to parse per service (default 5000)
  --json             JSON output
  --show-failures    Include failure event samples in JSON details

Exit codes:
  0 success
  1 error (journal command failure etc.)

Notes:
  - Requires journal access (run as root or user with permissions)
  - Heuristic parsing; complex services with multiple ExecStart phases may show larger durations
"""
from __future__ import annotations
import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
from typing import Dict, List, Optional

STARTING_RE = re.compile(r"Starting (.+?)\.\.\.")
STARTED_RE = re.compile(r"Started (.+?)\.")
FAILED_RE = re.compile(r"Failed to start (.+?)\.")

# journalctl line format we will request:  ISO8601 _SYSTEMD_UNIT= message
JOURNAL_FMT = "%Y-%m-%d %H:%M:%S"


def parse_args():
    p = argparse.ArgumentParser(description="Profile systemd service start latency via journal")
    p.add_argument("--services", help="Comma list of service unit names")
    p.add_argument("--pattern", help="Regex of service unit names")
    p.add_argument("--since", default="1d", help="Timespan passed to journalctl --since (default 1d)")
    p.add_argument("--limit", type=int, default=5000, help="Max lines per service to parse")
    p.add_argument("--json", action="store_true", help="JSON output")
    p.add_argument("--show-failures", action="store_true", help="Include failure samples in JSON details")
    return p.parse_args()


def list_all_services() -> List[str]:
    cp = subprocess.run(["systemctl", "list-units", "--type=service", "--all", "--no-legend"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if cp.returncode != 0:
        return []
    units = []
    for line in cp.stdout.splitlines():
        parts = line.split()
        if parts:
            unit = parts[0]
            if unit.endswith('.service'):
                units.append(unit)
    return units


def filter_services(all_units: List[str], services_arg: str | None, pattern: str | None) -> List[str]:
    chosen = set()
    if services_arg:
        for s in services_arg.split(','):
            s = s.strip()
            if s:
                chosen.add(s if s.endswith('.service') else s + '.service')
    import fnmatch, re as _re
    if pattern:
        rx = _re.compile(pattern)
        for u in all_units:
            if rx.search(u):
                chosen.add(u)
    return sorted(chosen) if chosen else all_units


def run_journal(unit: str, since: str, limit: int) -> List[str]:
    # Use short ISO date format for easier parsing; we will rely on journalctl default show all msgs
    cmd = ["journalctl", "-u", unit, "--since", since, "--no-pager", "--output=short-iso"]
    cp = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if cp.returncode != 0:
        return []
    lines = cp.stdout.splitlines()
    if limit and len(lines) > limit:
        lines = lines[-limit:]
    return lines


def parse_timestamp(line: str) -> Optional[float]:
    # short-iso begins with: YYYY-MM-DD HH:MM:SS
    try:
        ts_str = line[:19]
        import datetime as dt
        dt_obj = dt.datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S")
        return dt_obj.timestamp()
    except Exception:
        return None


def analyze_unit(unit: str, lines: List[str]):
    # We'll track states: start events, end events (success/fail)
    starts: List[float] = []
    durations: List[float] = []
    failures: List[Dict[str, float]] = []
    in_start = None
    for line in lines:
        ts = parse_timestamp(line)
        if ts is None:
            continue
        msg = line[19:].strip()
        if STARTING_RE.search(msg):
            in_start = ts
            starts.append(ts)
        elif STARTED_RE.search(msg):
            if in_start is not None:
                durations.append(ts - in_start)
                in_start = None
        elif FAILED_RE.search(msg):
            if in_start is not None:
                durations.append(ts - in_start)
                failures.append({'start': in_start, 'end': ts, 'duration': ts - in_start})
                in_start = None
    # If last start had no termination, ignore partial.
    stats = {
        'unit': unit,
        'starts': len(starts),
        'success': len(durations) - len(failures),
        'failures': len(failures),
        'durations': durations,
        'failure_samples': failures,
        'last_start_age_seconds': None,
    }
    if starts:
        last = starts[-1]
        stats['last_start_age_seconds'] = max(0, time.time() - last)
    return stats


def percentile(data: List[float], p: float) -> float:
    if not data:
        return 0.0
    return statistics.quantiles(data, n=100, method='inclusive')[int(p)-1]


def summarize(stats_list: List[Dict[str, any]]):
    rows = []
    for st in stats_list:
        durs = st['durations']
        if durs:
            p50 = percentile(durs, 50)
            p95 = percentile(durs, 95)
            mx = max(durs)
            mean = sum(durs)/len(durs)
        else:
            p50=p95=mx=mean=0.0
        rows.append({
            'unit': st['unit'],
            'starts': st['starts'],
            'success': st['success'],
            'failures': st['failures'],
            'p50': round(p50, 3),
            'p95': round(p95, 3),
            'max': round(mx, 3),
            'mean': round(mean, 3),
            'last_start_age_s': int(st['last_start_age_seconds']) if st['last_start_age_seconds'] is not None else None,
        })
    return rows


def print_table(rows):
    if not rows:
        print("No data")
        return
    header = f"{'Service':<35} {'Starts':>6} {'Succ':>5} {'Fail':>5} {'p50s':>7} {'p95s':>7} {'Maxs':>7} {'Mean':>7} {'LastStartAge':>12}"
    print(header)
    print('-'*len(header))
    for r in rows:
        print(f"{r['unit']:<35} {r['starts']:>6} {r['success']:>5} {r['failures']:>5} {r['p50']:>7} {r['p95']:>7} {r['max']:>7} {r['mean']:>7} {r['last_start_age_s'] if r['last_start_age_s'] is not None else 'n/a':>12}")


def main():
    args = parse_args()
    all_units = list_all_services()
    targets = filter_services(all_units, args.services, args.pattern)

    stats = []
    for unit in targets:
        lines = run_journal(unit, args.since, args.limit)
        if not lines:
            continue
        stats.append(analyze_unit(unit, lines))

    rows = summarize(stats)

    if args.json:
        out = { 'services': rows }
        if args.show_failures:
            out['failures'] = [
                {'unit': st['unit'], 'samples': st['failure_samples']} for st in stats if st['failure_samples']
            ]
        print(json.dumps(out, indent=2))
        return

    print_table(rows)


if __name__ == '__main__':
    main()
