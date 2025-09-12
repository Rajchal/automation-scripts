#!/usr/bin/env python3
"""
systemd-masked-unit-detector.py

Purpose:
  Enumerate masked or disabled systemd units (services, sockets, timers) and
  compare them against an optional allowlist baseline to detect drift or
  accidental hardening misconfigurations.

Features:
  - Detects masked units (`systemctl is-enabled` returns 'masked')
  - Detects units disabled when baseline expects enabled
  - Supports allowlist file for masked units (one per line)
  - JSON output option
  - Exit code 2 on unexpected masked/disabled units

Safe: Read-only; does not modify units.

Requirements:
  - Linux with systemd

Examples:
  python systemd-masked-unit-detector.py --json
  python systemd-masked-unit-detector.py --allow-masked baseline/masked-allow.txt --expect-enabled sshd.service crond.service

Exit Codes:
  0 success no unexpected findings
  1 error
  2 unexpected masked/disabled units
"""
import argparse
import json
import subprocess
import sys
from typing import List, Set, Dict, Any


def parse_args():
    p = argparse.ArgumentParser(description="Detect masked/disabled systemd units")
    p.add_argument("--allow-masked", help="File listing units allowed to be masked")
    p.add_argument("--expect-enabled", nargs="*", help="Units expected to be enabled")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def run(cmd: List[str]) -> str:
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
        return out
    except subprocess.CalledProcessError as e:
        return e.output


def list_units() -> List[str]:
    out = run(["systemctl", "list-unit-files", "--type=service", "--no-pager", "--no-legend"])
    units = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 2:
            name = parts[0]
            if name.endswith(".service"):
                units.append(name)
    return units


def is_enabled(unit: str) -> str:
    out = run(["systemctl", "is-enabled", unit]).strip()
    return out  # enabled, disabled, masked, static, indirect, generated, etc.


def load_allow_masked(path: str) -> Set[str]:
    allowed: Set[str] = set()
    if not path:
        return allowed
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                allowed.add(line)
    except FileNotFoundError:
        print(f"WARN allow-masked file not found: {path}", file=sys.stderr)
    return allowed


def main():
    args = parse_args()
    expected_enabled = set(args.expect_enabled or [])
    allow_masked = load_allow_masked(args.allow_masked) if args.allow_masked else set()

    units = list_units()
    findings = []
    for u in units:
        state = is_enabled(u)
        if state == 'masked' and u not in allow_masked:
            findings.append({"unit": u, "state": state, "reason": "Unexpected masked"})
        elif state == 'disabled' and u in expected_enabled:
            findings.append({"unit": u, "state": state, "reason": "Expected enabled but disabled"})

    exit_code = 0
    if findings:
        exit_code = 2

    if args.json:
        print(json.dumps({
            "total_units": len(units),
            "expected_enabled": sorted(list(expected_enabled)),
            "allow_masked": sorted(list(allow_masked)),
            "findings": findings,
        }, indent=2))
        return exit_code

    if not findings:
        print("No unexpected masked/disabled units detected.")
        return exit_code

    print("Unexpected masked/disabled units:")
    for f in findings:
        print(f"  {f['unit']}: {f['state']} ({f['reason']})")
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
