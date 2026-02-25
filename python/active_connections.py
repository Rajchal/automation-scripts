#!/usr/bin/env python3
"""active_connections.py

Lightweight Python wrapper to list active network connections.
This is a starter implementation mirroring `bash/active_connections.sh`.

Usage:
  python active_connections.py         # prints `ss -tunap`/`netstat -tunap` output
  python active_connections.py --filter 80  # show lines containing '80'
"""
from __future__ import annotations
import argparse
import shutil
import subprocess
import sys


def run_cmd(cmd: list[str]) -> int:
    try:
        p = subprocess.run(cmd, check=False)
        return p.returncode
    except FileNotFoundError:
        return 127


def capture_cmd(cmd: list[str]) -> str:
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        return p.stderr.strip()
    return p.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description="List active network connections")
    parser.add_argument("--filter", "-f", help="Filter output (substring)")
    parser.add_argument("--raw", action="store_true", help="Print raw command output")
    args = parser.parse_args()

    # Prefer ss, fall back to netstat
    if shutil.which("ss"):
        cmd = ["ss", "-tunap"]
    elif shutil.which("netstat"):
        cmd = ["netstat", "-tunap"]
    else:
        print("Neither 'ss' nor 'netstat' available on PATH.", file=sys.stderr)
        return 2

    output = capture_cmd(cmd)
    if args.raw:
        print(output)
        return 0

    lines = [l for l in output.splitlines() if l.strip()]
    if args.filter:
        lines = [l for l in lines if args.filter in l]

    # Simple pretty-print: header then matched lines
    if lines:
        for l in lines:
            print(l)
    else:
        print("No connections found matching filter." if args.filter else "No connections found.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
